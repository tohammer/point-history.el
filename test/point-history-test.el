;;; point-history-test.el --- Tests for point-history -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Tobias Hammer

;; Author: Tobias Hammer <tohammer@users.noreply.github.com>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; ERT tests for point-history.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'point-history)

(ert-deftest point-history-test-mode-toggle ()
  "Enabling and disabling the mode works."
  (let ((point-history-mode nil))
    (unwind-protect
        (progn
          (point-history-mode 1)
          (should point-history-mode)
          (point-history-mode -1)
          (should-not point-history-mode))
      (point-history-mode -1))))

(ert-deftest point-history-test-defaults ()
  "Option defaults match the spec."
  (should (equal (default-value 'point-history-size) 100))
  (should (equal (default-value 'point-history-distance) 10))
  (should (equal (default-value 'point-history-idle-delay) 2))
  (should (equal (default-value 'point-history-activity-commands)
                 '(kill-ring-save)))
  (should (equal (default-value 'point-history-ignored-edit-commands)
                 '(save-buffer save-some-buffers revert-buffer)))
  (should (eq (default-value 'point-history-record-file-visits) t))
  (should (equal (default-value 'point-history-visit-min-stay) 1))
  (should (eq (default-value 'point-history-file-buffers-only) t))
  (should (equal (default-value 'point-history-ignored-modes)
                 '(special-mode messages-buffer-mode git-commit-mode)))
  (should (eq (default-value 'point-history-message) t)))

;;;; Fixture and helpers

(defvar point-history-test--dir nil
  "Temporary directory of the running test.")

(defvar point-history-test--buffers nil
  "Buffers created by the running test.")

(defmacro point-history-test--with-fixture (&rest body)
  "Run BODY with an empty history, default options and a temp directory.
Buffers and files created by the helpers are removed afterwards."
  (declare (indent 0) (debug t))
  `(let ((point-history-test--dir (make-temp-file "point-history-test" t))
         (point-history-test--buffers nil)
         (point-history--entries nil)
         (point-history--index 0)
         (point-history--navigating nil)
         (point-history--last-navigation nil)
         (point-history--near-removed nil)
         (point-history--last-error nil)
         (point-history--pre-buffer nil)
         (point-history--pre-tick nil)
         (point-history-size 100)
         (point-history-distance 10)
         (point-history-activity-commands '(kill-ring-save))
         (point-history-ignored-edit-commands
          '(save-buffer save-some-buffers revert-buffer))
         (point-history-file-buffers-only t)
         (point-history-ignored-modes
          '(special-mode messages-buffer-mode git-commit-mode))
         (point-history-message t)
         (kill-ring nil))
     (unwind-protect
         (save-window-excursion
           ,@body)
       (dolist (buffer (append point-history-test--buffers (buffer-list)))
         (when (and (buffer-live-p buffer)
                    (or (memq buffer point-history-test--buffers)
                        (let ((file (buffer-file-name buffer)))
                          (and file
                               (string-prefix-p
                                (file-name-as-directory point-history-test--dir)
                                file)))))
           (with-current-buffer buffer
             (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory point-history-test--dir t))))

(defun point-history-test--file-buffer (name &optional lines)
  "Visit a new file NAME with LINES lines (default 200) and show it.
The buffer is shown in the selected window and made current."
  (let ((file (expand-file-name name point-history-test--dir)))
    (with-temp-file file
      (dotimes (i (or lines 200))
        (insert (format "line %d\n" (1+ i)))))
    (let ((buffer (find-file-noselect file)))
      (push buffer point-history-test--buffers)
      (switch-to-buffer buffer)
      (goto-char (point-min))
      buffer)))

(defun point-history-test--plain-buffer (name)
  "Create a buffer NAME that visits no file and show it."
  (let ((buffer (get-buffer-create name)))
    (push buffer point-history-test--buffers)
    (switch-to-buffer buffer)
    (insert "some text\n")
    buffer))

(defmacro point-history-test--command (command &rest body)
  "Run BODY as the command COMMAND, as the command loop does."
  (declare (indent 1) (debug t))
  `(let ((this-command ,command))
     (point-history--pre-command)
     ,@body
     (point-history--post-command)))

(defun point-history-test--goto-line (line)
  "Move point to the beginning of LINE."
  (goto-char (point-min))
  (forward-line (1- line)))

(defun point-history-test--edit-at (line)
  "Run an edit command that inserts a character at LINE."
  (point-history-test--command 'self-insert-command
    (point-history-test--goto-line line)
    (insert "x")))

(defun point-history-test--lines ()
  "Return the line numbers of the history entries, newest first."
  (mapcar (lambda (entry)
            (let ((marker (point-history--entry-marker entry)))
              (with-current-buffer (marker-buffer marker)
                (line-number-at-pos marker))))
          point-history--entries))

;;;; Recording

(ert-deftest point-history-test-moves-record-nothing ()
  "Cursor moves of any distance without pausing record nothing."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (dolist (n '(1 5 50 -30 100))
      (point-history-test--command 'next-line
        (forward-line n)))
    (point-history-test--command 'end-of-buffer
      (goto-char (point-max)))
    (should (null point-history--entries))))

(ert-deftest point-history-test-edit-records ()
  "An edit records, near edits move it, a far edit adds an entry."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 20)
    (should (equal (point-history-test--lines) '(20)))
    (let ((entry (car point-history--entries)))
      (should (eq (point-history--entry-kind entry) 'activity))
      (should (equal (point-history--entry-file entry) buffer-file-name))
      (point-history-test--edit-at 25)
      (point-history-test--edit-at 30)
      (should (equal (point-history-test--lines) '(30)))
      (should (eq (car point-history--entries) entry)))
    (point-history-test--edit-at 41)
    (should (equal (point-history-test--lines) '(41 30)))))

(ert-deftest point-history-test-ignored-edit-command ()
  "A buffer change by an ignored edit command records nothing."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--command 'save-buffer
      (point-history-test--goto-line 10)
      (insert "formatted")
      (save-buffer))
    (should (null point-history--entries))))

(ert-deftest point-history-test-change-outside-command ()
  "A change made between commands records nothing."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    ;; As done by a timer or process output, outside any command.
    (point-history-test--goto-line 10)
    (insert "output")
    (point-history-test--command 'next-line
      (forward-line 1))
    (should (null point-history--entries))))

(ert-deftest point-history-test-property-change-records-nothing ()
  "A command that only changes text properties records nothing."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--command 'some-fontify-command
      (put-text-property (point-min) (point-max) 'face 'bold))
    (should (null point-history--entries))))

(ert-deftest point-history-test-edit-ending-in-other-buffer ()
  "A command that edits and ends in another buffer records no edit."
  (point-history-test--with-fixture
    (let ((a (point-history-test--file-buffer "a.txt")))
      (point-history-test--file-buffer "b.txt")
      ;; Give b a change tick that differs from a's.
      (dotimes (_ 5) (insert "y"))
      (switch-to-buffer a)
      (point-history-test--command 'some-macro
        (point-history-test--goto-line 10)
        (insert "x")
        (switch-to-buffer (get-file-buffer
                           (expand-file-name "b.txt" point-history-test--dir))))
      (should (null point-history--entries)))))

(ert-deftest point-history-test-copy-records ()
  "A copy command records."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--command 'kill-ring-save
      (point-history-test--goto-line 15)
      (kill-ring-save (point) (line-end-position)))
    (should (equal (point-history-test--lines) '(15)))))

(ert-deftest point-history-test-idle-records-once ()
  "Idle time records at point, once per place."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--goto-line 50)
    (point-history--idle)
    (point-history--idle)
    (should (equal (point-history-test--lines) '(50)))))

(ert-deftest point-history-test-near-older-entry-moves-to-front ()
  "Activity near an older entry moves that entry to the front."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 1)
    (point-history-test--edit-at 30)
    (point-history-test--edit-at 60)
    (should (equal (point-history-test--lines) '(60 30 1)))
    (let ((old (nth 2 point-history--entries)))
      (point-history-test--edit-at 3)
      (should (equal (point-history-test--lines) '(3 60 30)))
      (should (equal point-history--near-removed (cons old 2))))))

(ert-deftest point-history-test-size-limit ()
  "The history never exceeds `point-history-size'."
  (point-history-test--with-fixture
    (let ((point-history-size 5))
      (point-history-test--file-buffer "a.txt" 300)
      (let ((first nil))
        (dotimes (i 10)
          (point-history-test--edit-at (1+ (* i 20)))
          (unless first (setq first (car point-history--entries)))
          (should (<= (length point-history--entries) 5)))
        (should (equal (point-history-test--lines) '(181 161 141 121 101)))
        (should-not (marker-buffer (point-history--entry-marker first)))))))

(ert-deftest point-history-test-ignored-mode ()
  "Buffers in ignored modes, or modes derived from them, are not recorded."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (special-mode)
    (point-history--idle)
    (should (null point-history--entries))
    (point-history-test--file-buffer "b.txt")
    (let ((point-history-ignored-modes '(prog-mode)))
      (emacs-lisp-mode)
      (point-history--idle)
      (should (null point-history--entries)))))

(ert-deftest point-history-test-non-file-buffer ()
  "Non-file buffers are recorded only if `point-history-file-buffers-only' is nil."
  (point-history-test--with-fixture
    (point-history-test--plain-buffer "*point-history-test*")
    (point-history--idle)
    (should (null point-history--entries))
    (let ((point-history-file-buffers-only nil))
      (point-history--idle)
      (should (= (length point-history--entries) 1)))))

(ert-deftest point-history-test-minibuffer-not-recordable ()
  "The minibuffer is not recordable."
  (point-history-test--with-fixture
    (let ((point-history-file-buffers-only nil))
      (should-not (point-history--recordable-p
                   (window-buffer (minibuffer-window)))))))

(ert-deftest point-history-test-rule-1-while-navigating ()
  "Activity near the current entry moves it and keeps forward history."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 1)
    (point-history-test--edit-at 30)
    (point-history-test--edit-at 60)
    (setq point-history--index 1)
    (let ((entries (copy-sequence point-history--entries)))
      (point-history-test--edit-at 34)
      (should (equal (point-history-test--lines) '(60 34 1)))
      (should (equal point-history--entries entries))
      (should (= point-history--index 1)))))

(ert-deftest point-history-test-rule-3-while-navigating ()
  "A new place while navigating drops the forward history and resets the index."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 1)
    (point-history-test--edit-at 30)
    (point-history-test--edit-at 60)
    (point-history-test--edit-at 90)
    (setq point-history--index 2)
    (let ((dropped (car point-history--entries)))
      (point-history-test--edit-at 120)
      (should (equal (point-history-test--lines) '(120 30 1)))
      (should (= point-history--index 0))
      (should-not (marker-buffer (point-history--entry-marker dropped))))
    ;; With a near entry in the remaining history.
    (setq point-history--index 1)
    (point-history-test--edit-at 2)
    (should (equal (point-history-test--lines) '(2 30)))
    (should (= point-history--index 0))
    (should (= (cdr point-history--near-removed) 1))))

(ert-deftest point-history-test-rule-2-replaces-visit ()
  "Activity replaces a newest visit entry in the same buffer, however far."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "b.txt")
    (point-history-test--edit-at 5)
    (point-history-test--file-buffer "a.txt")
    (let ((visit (point-history--new-entry 'visit)))
      (push visit point-history--entries)
      (point-history-test--edit-at 150)
      (should (= (length point-history--entries) 2))
      (should (eq (car point-history--entries) visit))
      (should (eq (point-history--entry-kind visit) 'activity))
      (should (equal (point-history-test--lines) '(150 5))))))

(ert-deftest point-history-test-idle-while-navigating ()
  "Idle time does not record while navigating."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (let ((point-history--navigating t))
      (point-history--idle))
    (should (null point-history--entries))))

(defun point-history-test--nav-command ()
  "A command marked as navigation, for tests."
  (interactive))
(put 'point-history-test--nav-command 'point-history-navigation t)

(ert-deftest point-history-test-navigation-command-never-records ()
  "A command marked as navigation never counts as activity."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--command 'point-history-test--nav-command
      (insert "x"))
    (let ((point-history-activity-commands '(point-history-test--nav-command)))
      (point-history-test--command 'point-history-test--nav-command
        (ignore)))
    (should (null point-history--entries))))

(ert-deftest point-history-test-errors-are-caught ()
  "Errors in the hooks and the timer are reported once and not signaled."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (let ((messages nil))
      (cl-letf (((symbol-function 'point-history--activity)
                 (lambda (&rest _) (error "Boom")))
                ((symbol-function 'message)
                 (lambda (format &rest args)
                   (push (apply #'format-message format args) messages))))
        (point-history-test--edit-at 10)
        (point-history-test--edit-at 50)
        (point-history--idle))
      (should (equal messages '("point-history: Boom"))))
    (should (null point-history--entries))))

(ert-deftest point-history-test-mode-hooks-and-timer ()
  "Mode off removes hooks and timer; mode on again keeps the history."
  (point-history-test--with-fixture
    (let ((point-history-mode nil)
          (point-history--timer nil)
          (point-history-idle-delay 2))
      (unwind-protect
          (progn
            (point-history-mode 1)
            (should (memq #'point-history--pre-command pre-command-hook))
            (should (memq #'point-history--post-command post-command-hook))
            (should (memq #'point-history--kill-buffer kill-buffer-hook))
            (should (memq point-history--timer timer-idle-list))
            (point-history-test--file-buffer "a.txt")
            (point-history-test--edit-at 10)
            (let ((timer point-history--timer)
                  (entries point-history--entries))
              (point-history-mode -1)
              (should-not (memq #'point-history--pre-command pre-command-hook))
              (should-not (memq #'point-history--post-command
                                post-command-hook))
              (should-not (memq #'point-history--kill-buffer
                                kill-buffer-hook))
              (should-not (memq timer timer-idle-list))
              (should-not point-history--timer)
              (point-history-mode 1)
              (should (eq point-history--entries entries))
              (should (equal (point-history-test--lines) '(10)))))
        (point-history-mode -1)))))

(ert-deftest point-history-test-idle-delay-nil ()
  "A nil `point-history-idle-delay' starts no timer."
  (let ((point-history-mode nil)
        (point-history--timer nil)
        (point-history-idle-delay nil))
    (unwind-protect
        (progn
          (point-history-mode 1)
          (should-not point-history--timer))
      (point-history-mode -1))))

;;;; Navigation

(defmacro point-history-test--with-mode (&rest body)
  "Run BODY with `point-history-mode' on and no idle timer."
  (declare (indent 0) (debug t))
  `(let ((point-history-mode nil)
         (point-history--timer nil)
         (point-history-idle-delay nil))
     (unwind-protect
         (progn
           (point-history-mode 1)
           ,@body)
       (point-history-mode -1))))

(defun point-history-test--run (command)
  "Run COMMAND as the command loop does; return its messages, oldest first."
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest args)
                 (when format
                   (push (apply #'format-message format args) messages)))))
      (point-history-test--command command
        (call-interactively command)))
    (nreverse messages)))

(defun point-history-test--back ()
  "Run `point-history-back' and return its messages."
  (point-history-test--run 'point-history-back))

(defun point-history-test--forward ()
  "Run `point-history-forward' and return its messages."
  (point-history-test--run 'point-history-forward))

(defun point-history-test--move-to (line)
  "Run a motion command that moves point to LINE."
  (point-history-test--command 'next-line
    (point-history-test--goto-line line)))

(defun point-history-test--here ()
  "Return (BUFFER-NAME . LINE) of point in the selected window."
  (let ((window (selected-window)))
    (with-current-buffer (window-buffer window)
      (cons (buffer-name) (line-number-at-pos (window-point window))))))

(defun point-history-test--places ()
  "Return (BUFFER-NAME . LINE) of each history entry, newest first."
  (mapcar (lambda (entry)
            (let ((marker (point-history--entry-marker entry)))
              (with-current-buffer (marker-buffer marker)
                (cons (buffer-name) (line-number-at-pos marker)))))
          point-history--entries))

(defun point-history-test--kinds ()
  "Return the kinds of the history entries, newest first."
  (mapcar #'point-history--entry-kind point-history--entries))

(defun point-history-test--file (name)
  "Return the file name of NAME in the test directory."
  (expand-file-name name point-history-test--dir))

(ert-deftest point-history-test-navigation-commands-marked ()
  "The navigation commands are marked as such and are commands."
  (dolist (command '(point-history-back point-history-forward))
    (should (commandp command))
    (should (point-history--navigation-command-p command))))

(ert-deftest point-history-test-empty-history ()
  "Navigation with an empty history says so and records nothing."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--move-to 50)
    (should (equal (point-history-test--back) '("No places recorded yet")))
    (should (equal (point-history-test--forward) '("No places recorded yet")))
    (should (null point-history--entries))))

(ert-deftest point-history-test-back-forward-order ()
  "Back and forward go through the history across files, with messages."
  (point-history-test--with-fixture
    (let ((a (point-history-test--file-buffer "a.txt")))
      (point-history-test--edit-at 10)
      (point-history-test--file-buffer "b.txt")
      (point-history-test--edit-at 20)
      (point-history-test--file-buffer "c.txt")
      (point-history-test--edit-at 30)
      (switch-to-buffer a)
      (point-history-test--edit-at 100)
      (let ((places '(("a.txt" . 100) ("c.txt" . 30)
                      ("b.txt" . 20) ("a.txt" . 10))))
        (should (equal (point-history-test--places) places))
        (should (equal (point-history-test--back) '("Back 2/4")))
        (should (equal (point-history-test--here) '("c.txt" . 30)))
        (should (equal (point-history-test--back) '("Back 3/4")))
        (should (equal (point-history-test--here) '("b.txt" . 20)))
        (should (equal (point-history-test--back) '("Back 4/4")))
        (should (equal (point-history-test--here) '("a.txt" . 10)))
        (should (equal (point-history-test--back) '("At oldest place")))
        (should (equal (point-history-test--here) '("a.txt" . 10)))
        (should (= point-history--index 3))
        (should (equal (point-history-test--forward) '("Forward 3/4")))
        (should (equal (point-history-test--here) '("b.txt" . 20)))
        (should (equal (point-history-test--forward) '("Forward 2/4")))
        (should (equal (point-history-test--here) '("c.txt" . 30)))
        (let ((point-history-message nil))
          (should (null (point-history-test--forward))))
        (should (equal (point-history-test--here) '("a.txt" . 100)))
        (should (equal (point-history-test--forward) '("At newest place")))
        (should (equal (point-history-test--here) '("a.txt" . 100)))
        (should (= point-history--index 0))
        (should (equal (point-history-test--places) places))
        (should (equal (point-history-test--kinds)
                       '(activity activity activity activity)))))))

(ert-deftest point-history-test-return-point-at-front ()
  "Back from a place away from the newest entry remembers that place."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 10)
    (point-history-test--edit-at 50)
    (point-history-test--move-to 150)
    (should (equal (point-history-test--back) '("Back 2/3")))
    (should (equal (point-history-test--here) '("a.txt" . 50)))
    (should (equal (point-history-test--lines) '(150 50 10)))
    (should (equal (point-history-test--kinds) '(return activity activity)))
    (should (= point-history--index 1))
    (should (equal (point-history-test--forward) '("Forward 1/3")))
    (should (equal (point-history-test--here) '("a.txt" . 150)))
    (should (equal (point-history-test--forward) '("At newest place")))
    (should (equal (point-history-test--lines) '(150 50 10)))))

;; Forward with nothing newer must not leave a return entry behind.
(ert-deftest point-history-test-forward-at-newest-adds-nothing ()
  "Forward at index 0 away from the newest entry inserts no return entry."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 10)
    (point-history-test--edit-at 50)
    (point-history-test--move-to 150)
    (should (equal (point-history-test--forward) '("At newest place")))
    (should (equal (point-history-test--lines) '(50 10)))
    (should (equal (point-history-test--back) '("Back 2/3")))))

(ert-deftest point-history-test-no-return-point-near-newest ()
  "Back from a place near the newest entry adds no return entry."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 10)
    (point-history-test--edit-at 50)
    (point-history-test--move-to 58)
    (should (equal (point-history-test--back) '("Back 2/2")))
    (should (equal (point-history-test--here) '("a.txt" . 10)))
    (should (equal (point-history-test--lines) '(50 10)))))

(ert-deftest point-history-test-return-point-only-after-other-command ()
  "Only the first navigation command after another command adds a return entry."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 10)
    (point-history-test--edit-at 50)
    (point-history-test--edit-at 90)
    (point-history-test--back)
    (should point-history--last-navigation)
    ;; Point moved away without a command in between (e.g. by a timer).
    (point-history-test--goto-line 150)
    (point-history-test--back)
    (should (equal (point-history-test--lines) '(90 50 10)))
    (point-history-test--move-to 150)
    (should-not point-history--last-navigation)
    (point-history-test--back)
    (should (equal (point-history-test--lines) '(90 50 150 10)))))

(ert-deftest point-history-test-return-point-size-limit ()
  "Inserting a return entry respects `point-history-size'."
  (point-history-test--with-fixture
    (let ((point-history-size 3))
      (point-history-test--file-buffer "a.txt")
      (point-history-test--edit-at 10)
      (point-history-test--edit-at 50)
      (point-history-test--edit-at 90)
      (point-history-test--move-to 150)
      (point-history-test--back)
      (should (equal (point-history-test--lines) '(150 90 50)))
      (should (equal (point-history-test--here) '("a.txt" . 90))))))

(ert-deftest point-history-test-return-point-not-recordable ()
  "In a buffer that is not recordable no return entry is added.
Back then goes to the current entry itself."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 10)
    (point-history-test--edit-at 50)
    (point-history-test--plain-buffer "*point-history-test*")
    (should (equal (point-history-test--back) '("Back 1/2")))
    (should (equal (point-history-test--here) '("a.txt" . 50)))
    (should (equal (point-history-test--lines) '(50 10)))
    (point-history-test--plain-buffer "*point-history-test*")
    (should (equal (point-history-test--forward) '("At newest place")))
    (should (equal (point-history-test--lines) '(50 10)))))

(ert-deftest point-history-test-small-move-after-back ()
  "A small move after back, then back, adds no return entry."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 10)
    (point-history-test--edit-at 50)
    (point-history-test--edit-at 90)
    (point-history-test--back)
    (should (equal (point-history-test--here) '("a.txt" . 50)))
    (point-history-test--command 'next-line
      (forward-line 1))
    (should point-history--navigating)
    (should (equal (point-history-test--back) '("Back 3/3")))
    (should (equal (point-history-test--here) '("a.txt" . 10)))
    (should (equal (point-history-test--lines) '(90 50 10)))
    (should (equal (point-history-test--kinds) '(activity activity activity)))))

(ert-deftest point-history-test-move-away-after-back ()
  "Moving away after back, then back, inserts a return entry before the current one."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 10)
    (point-history-test--edit-at 50)
    (point-history-test--edit-at 90)
    (point-history-test--edit-at 130)
    (point-history-test--back)
    (point-history-test--back)
    (should (equal (point-history-test--here) '("a.txt" . 50)))
    (point-history-test--move-to 180)
    (should-not point-history--navigating)
    (should (= point-history--index 2))
    (should (equal (point-history-test--back) '("Back 4/5")))
    (should (equal (point-history-test--here) '("a.txt" . 50)))
    (should (equal (point-history-test--lines) '(130 90 180 50 10)))
    (should (eq (point-history--entry-kind (nth 2 point-history--entries))
                'return))
    (should (equal (point-history-test--forward) '("Forward 3/5")))
    (should (equal (point-history-test--here) '("a.txt" . 180)))
    (should (equal (point-history-test--forward) '("Forward 2/5")))
    (should (equal (point-history-test--here) '("a.txt" . 90)))
    (should (equal (point-history-test--forward) '("Forward 1/5")))
    (should (equal (point-history-test--here) '("a.txt" . 130)))
    (should (equal (point-history-test--forward) '("At newest place")))))

(ert-deftest point-history-test-navigating-state ()
  "At the target idle does not record; an edit there moves the entry in place."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 10)
    (point-history-test--edit-at 50)
    (point-history-test--edit-at 90)
    (point-history-test--back)
    (should point-history--navigating)
    (point-history-test--move-to 53)
    (point-history--idle)
    (should (equal (point-history-test--lines) '(90 50 10)))
    (let ((entries (copy-sequence point-history--entries)))
      (point-history-test--edit-at 54)
      (should (equal (point-history-test--lines) '(90 54 10)))
      (should (equal point-history--entries entries))
      (should (= point-history--index 1))
      (should point-history--navigating))
    (should (equal (point-history-test--forward) '("Forward 1/3")))
    (should (equal (point-history-test--here) '("a.txt" . 90)))))

(ert-deftest point-history-test-moving-away-ends-navigating ()
  "Moving away ends the navigating state; idle then records by rule 3."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 10)
    (point-history-test--edit-at 50)
    (point-history-test--edit-at 90)
    (point-history-test--edit-at 130)
    (point-history-test--back)
    (point-history-test--back)
    (should point-history--navigating)
    (point-history-test--command 'next-line
      (forward-line 125))
    (should-not point-history--navigating)
    (should (= point-history--index 2))
    (point-history--idle)
    (should (equal (point-history-test--lines) '(175 50 10)))
    (should (= point-history--index 0))))

(ert-deftest point-history-test-other-buffer-ends-navigating ()
  "Showing another buffer ends the navigating state; the index stays."
  (point-history-test--with-fixture
    (let ((b (point-history-test--file-buffer "b.txt")))
      (point-history-test--file-buffer "a.txt")
      (point-history-test--edit-at 10)
      (point-history-test--edit-at 50)
      (point-history-test--back)
      (should point-history--navigating)
      (point-history-test--command 'switch-to-buffer
        (switch-to-buffer b))
      (should-not point-history--navigating)
      (should (= point-history--index 1)))))

(ert-deftest point-history-test-new-place-drops-forward-history ()
  "Activity far away while navigating drops the forward history; near does not."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--edit-at 10)
    (point-history-test--edit-at 50)
    (point-history-test--edit-at 90)
    (point-history-test--back)
    (point-history-test--back)
    (point-history-test--edit-at 12)
    (should (equal (point-history-test--lines) '(90 50 12)))
    (should (= point-history--index 2))
    (point-history-test--edit-at 150)
    (should (equal (point-history-test--lines) '(150 12)))
    (should (= point-history--index 0))
    (should-not point-history--navigating)
    (should (equal (point-history-test--forward) '("At newest place")))))

(ert-deftest point-history-test-killed-buffer-reopened ()
  "An entry of a killed buffer reopens its file at the stored position."
  (point-history-test--with-fixture
    (point-history-test--with-mode
      (let ((a (point-history-test--file-buffer "a.txt")))
        (point-history-test--edit-at 20)
        (point-history-test--edit-at 120)
        (save-buffer)
        (let ((position (point)))
          (point-history-test--file-buffer "b.txt")
          (point-history-test--edit-at 5)
          (kill-buffer a)
          (should-not (marker-buffer (point-history--entry-marker
                                      (nth 1 point-history--entries))))
          (should (= (point-history--entry-position
                      (nth 1 point-history--entries))
                     position))
          (should (equal (point-history-test--back) '("Back 2/3")))
          (should (equal (buffer-file-name) (point-history-test--file "a.txt")))
          (should (eq (window-buffer (selected-window)) (current-buffer)))
          (should (= (point) position))
          (should (equal (point-history-test--places)
                         '(("b.txt" . 5) ("a.txt" . 120) ("a.txt" . 20))))
          (should (eq (marker-buffer (point-history--entry-window-start
                                      (nth 2 point-history--entries)))
                      (current-buffer)))
          (should (equal (point-history-test--back) '("Back 3/3")))
          (should (equal (point-history-test--here) '("a.txt" . 20))))))))

(ert-deftest point-history-test-killed-buffer-without-position ()
  "An entry killed while the mode was off reopens at the beginning."
  (point-history-test--with-fixture
    (let ((a (point-history-test--file-buffer "a.txt")))
      (point-history-test--edit-at 120)
      (save-buffer)
      (point-history-test--file-buffer "b.txt")
      (point-history-test--edit-at 5)
      (kill-buffer a)
      (should (equal (point-history-test--back) '("Back 2/2")))
      (should (equal (point-history-test--here) '("a.txt" . 1))))))

(ert-deftest point-history-test-killed-buffer-shrunken-file ()
  "A stored position beyond the end of the reopened file is clamped."
  (point-history-test--with-fixture
    (point-history-test--with-mode
      (let ((a (point-history-test--file-buffer "a.txt")))
        (point-history-test--edit-at 150)
        (save-buffer)
        (point-history-test--file-buffer "b.txt")
        (point-history-test--edit-at 5)
        (kill-buffer a)
        (with-temp-file (point-history-test--file "a.txt")
          (insert "short\n"))
        (point-history-test--back)
        (should (equal (buffer-file-name) (point-history-test--file "a.txt")))
        (should (= (point) (point-max)))
        (let ((entry (nth 1 point-history--entries)))
          (should (<= (point-history--entry-marker entry) (point-max)))
          (should (<= (point-history--entry-window-start entry)
                      (point-max))))))))

(ert-deftest point-history-test-deleted-file-skipped-back ()
  "Going back, an entry whose file is gone is removed and skipped."
  (point-history-test--with-fixture
    (point-history-test--with-mode
      (point-history-test--file-buffer "a.txt")
      (point-history-test--edit-at 10)
      (let ((b (point-history-test--file-buffer "b.txt")))
        (point-history-test--edit-at 20)
        (point-history-test--file-buffer "c.txt")
        (point-history-test--edit-at 30)
        (with-current-buffer b (set-buffer-modified-p nil))
        (kill-buffer b)
        (delete-file (point-history-test--file "b.txt"))
        (should (equal (point-history-test--back)
                       (list (format "point-history: removed %s, file no longer exists"
                                     (point-history-test--file "b.txt"))
                             "Back 2/2")))
        (should (equal (point-history-test--here) '("a.txt" . 10)))
        (should (equal (point-history-test--places)
                       '(("c.txt" . 30) ("a.txt" . 10))))))))

(ert-deftest point-history-test-deleted-file-skipped-forward ()
  "Going forward, an entry whose file is gone is removed; the index stays right."
  (point-history-test--with-fixture
    (point-history-test--with-mode
      (point-history-test--file-buffer "a.txt")
      (point-history-test--edit-at 10)
      (let ((b (point-history-test--file-buffer "b.txt")))
        (point-history-test--edit-at 20)
        (point-history-test--file-buffer "c.txt")
        (point-history-test--edit-at 30)
        (point-history-test--file-buffer "d.txt")
        (point-history-test--edit-at 40)
        (point-history-test--back)
        (point-history-test--back)
        (point-history-test--back)
        (should (equal (point-history-test--here) '("a.txt" . 10)))
        (with-current-buffer b (set-buffer-modified-p nil))
        (kill-buffer b)
        (delete-file (point-history-test--file "b.txt"))
        (should (equal (point-history-test--forward)
                       (list (format "point-history: removed %s, file no longer exists"
                                     (point-history-test--file "b.txt"))
                             "Forward 2/3")))
        (should (equal (point-history-test--here) '("c.txt" . 30)))
        (should (= point-history--index 1))
        (should (equal (point-history-test--forward) '("Forward 1/3")))
        (should (equal (point-history-test--here) '("d.txt" . 40)))
        (should (equal (point-history-test--back) '("Back 2/3")))
        (should (equal (point-history-test--back) '("Back 3/3")))
        (should (equal (point-history-test--here) '("a.txt" . 10)))))))

(ert-deftest point-history-test-deleted-file-at-newest-keeps-index ()
  "Removing the only newer entry keeps the index on the current entry."
  (point-history-test--with-fixture
    (point-history-test--with-mode
      (point-history-test--file-buffer "o.txt")
      (point-history-test--edit-at 5)
      (point-history-test--file-buffer "a.txt")
      (point-history-test--edit-at 10)
      (let ((b (point-history-test--file-buffer "b.txt")))
        (point-history-test--edit-at 20)
        (point-history-test--back)
        (should (equal (point-history-test--here) '("a.txt" . 10)))
        (with-current-buffer b (set-buffer-modified-p nil))
        (kill-buffer b)
        (delete-file (point-history-test--file "b.txt"))
        (should (equal (point-history-test--forward)
                       (list (format "point-history: removed %s, file no longer exists"
                                     (point-history-test--file "b.txt"))
                             "At newest place")))
        (should (= point-history--index 0))
        (should (equal (point-history-test--back) '("Back 2/2")))
        (should (equal (point-history-test--here) '("o.txt" . 5)))))))

(ert-deftest point-history-test-killed-non-file-buffer-skipped ()
  "An entry of a killed buffer without a file is removed and skipped."
  (point-history-test--with-fixture
    (let ((point-history-file-buffers-only nil))
      (point-history-test--file-buffer "a.txt")
      (point-history-test--edit-at 10)
      (let ((plain (point-history-test--plain-buffer "*point-history-test*")))
        (point-history--idle)
        (point-history-test--file-buffer "b.txt")
        (point-history-test--edit-at 5)
        (should (= (length point-history--entries) 3))
        (kill-buffer plain)
        (should (equal (point-history-test--back)
                       '("point-history: removed entry, its buffer was killed"
                         "Back 2/2")))
        (should (equal (point-history-test--here) '("a.txt" . 10)))))))

(ert-deftest point-history-test-kill-buffer-errors-caught ()
  "Errors in the kill-buffer hook function are reported, not signaled."
  (point-history-test--with-fixture
    (let ((messages nil))
      (cl-letf (((symbol-function 'point-history--all-entries)
                 (lambda () (error "Boom")))
                ((symbol-function 'message)
                 (lambda (format &rest args)
                   (push (apply #'format-message format args) messages))))
        (point-history--kill-buffer))
      (should (equal messages '("point-history: Boom"))))))

(ert-deftest point-history-test-window-start-restored-when-not-visible ()
  "The remembered window start is restored only if the target is not visible."
  (point-history-test--with-fixture
    (point-history-test--file-buffer "a.txt")
    (point-history-test--goto-line 15)
    (let ((start (point)))
      (set-window-start (selected-window) start)
      (point-history-test--edit-at 20)
      (should (= (point-history--entry-window-start
                  (car point-history--entries))
                 start))
      (point-history-test--edit-at 150)
      (point-history-test--goto-line 140)
      (let ((other (point)))
        (set-window-start (selected-window) other)
        (cl-letf (((symbol-function 'pos-visible-in-window-p)
                   (lambda (&rest _) t)))
          (point-history-test--back))
        (should (equal (point-history-test--here) '("a.txt" . 20)))
        (should (= (window-start (selected-window)) other))
        (cl-letf (((symbol-function 'pos-visible-in-window-p)
                   (lambda (&rest _) t)))
          (point-history-test--forward))
        (should (equal (point-history-test--here) '("a.txt" . 150)))
        (should (= (window-start (selected-window)) other))
        (cl-letf (((symbol-function 'pos-visible-in-window-p)
                   (lambda (&rest _) nil)))
          (point-history-test--back))
        (should (equal (point-history-test--here) '("a.txt" . 20)))
        (should (= (window-start (selected-window)) start))))))

(ert-deftest point-history-test-dedicated-window-pops ()
  "In a dedicated window the target is shown with `pop-to-buffer'."
  (point-history-test--with-fixture
    (let ((a (point-history-test--file-buffer "a.txt"))
          (calls nil))
      (point-history-test--edit-at 10)
      (point-history-test--file-buffer "b.txt")
      (point-history-test--edit-at 20)
      (unwind-protect
          (progn
            (set-window-dedicated-p (selected-window) t)
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (buffer &rest _)
                         (push buffer calls)
                         (set-buffer buffer)))
                      ((symbol-function 'switch-to-buffer)
                       (lambda (&rest _) (error "switch-to-buffer called"))))
              (point-history-test--back)))
        (set-window-dedicated-p (selected-window) nil))
      (should (equal calls (list a)))
      (should (eq (current-buffer) a))
      (should (= (line-number-at-pos) 10)))))

(provide 'point-history-test)
;;; point-history-test.el ends here
