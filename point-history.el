;;; point-history.el --- Back/forward navigation by activity -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Tobias Hammer

;; Author: Tobias Hammer <tohammer@users.noreply.github.com>
;; Version: 0.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: convenience
;; URL: https://github.com/tohammer/point-history.el

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; point-history records the places where you edited or read text and
;; lets you move back and forward through them, like the back and
;; forward buttons of a browser.  Places are recorded by activity
;; (edits, copying, reading pauses and file visits), not by every
;; cursor movement.
;;
;; Enable the global minor mode `point-history-mode' to start recording.

;;; Code:

(require 'cl-lib)

(defgroup point-history nil
  "Back/forward navigation by activity."
  :group 'convenience
  :prefix "point-history-")

(defcustom point-history-size 100
  "Maximum number of history entries."
  :type 'integer
  :group 'point-history)

(defcustom point-history-distance 10
  "Number of lines within which two places count as the same place."
  :type 'integer
  :group 'point-history)

(defcustom point-history-idle-delay 2
  "Seconds without input that count as reading.
If nil, recording of reading pauses is disabled.  A change takes
effect when `point-history-mode' is enabled again."
  :type '(choice (const :tag "Off" nil) number)
  :group 'point-history)

(defcustom point-history-activity-commands '(kill-ring-save)
  "Commands that count as activity besides edits."
  :type '(repeat symbol)
  :group 'point-history)

(defcustom point-history-ignored-edit-commands
  '(save-buffer save-some-buffers revert-buffer)
  "Commands whose buffer changes are not activity.
This covers, for example, format-on-save and reverting."
  :type '(repeat symbol)
  :group 'point-history)

(defcustom point-history-record-file-visits t
  "Non-nil means entering another file adds a placeholder entry."
  :type 'boolean
  :group 'point-history)

(defcustom point-history-visit-min-stay 1
  "Seconds a file visit must last to be kept."
  :type 'number
  :group 'point-history)

(defcustom point-history-file-buffers-only t
  "Non-nil means only record buffers that visit a file."
  :type 'boolean
  :group 'point-history)

(defcustom point-history-ignored-modes
  '(special-mode messages-buffer-mode git-commit-mode)
  "Major modes never recorded.
Modes derived from these are ignored as well."
  :type '(repeat symbol)
  :group 'point-history)

(defcustom point-history-message t
  "Non-nil means echo the position after a move, e.g. \"Back 3/42\"."
  :type 'boolean
  :group 'point-history)

;;;; History

(cl-defstruct (point-history--entry
               (:constructor point-history--make-entry)
               (:copier nil))
  "A remembered place.
MARKER is the position, FILE the file name of its buffer or nil,
WINDOW-START a marker at the window start when it was recorded and
KIND one of `activity', `visit' or `return'.  When the buffer of
MARKER is killed, POSITION and START-POSITION hold the positions of
MARKER and WINDOW-START at that time, so that the entry can be
reopened; they are nil otherwise."
  marker file window-start kind position start-position)

(defvar point-history--entries nil
  "The history: a list of `point-history--entry', newest first.")

(defvar point-history--index 0
  "Position in `point-history--entries' of the current entry.
It is 0 when not navigating.")

(defvar point-history--navigating nil
  "Non-nil while the user is navigating through the history.
While non-nil, idle time does not record.")

(defvar point-history--near-removed nil
  "The entry removed by the near rule in the last new recording.
A cons (ENTRY . POSITION), where POSITION is the entry's former
position in `point-history--entries' after the forward history was
dropped and before the new entry was added, or nil if no entry was
removed.  The marker of ENTRY is kept alive so it can be put back.")

(defvar point-history--last-navigation nil
  "Non-nil if the last command was a navigation command.
Set by `point-history--post-command'.")

(defun point-history--release (entry)
  "Release the markers of ENTRY."
  (set-marker (point-history--entry-marker entry) nil)
  (set-marker (point-history--entry-window-start entry) nil))

(defun point-history--release-unless-listed (entry)
  "Release the markers of ENTRY unless it is in the history."
  (unless (memq entry point-history--entries)
    (point-history--release entry)))

(defun point-history--window-start ()
  "Return the window start to remember for point in the current buffer.
This is the selected window's start if it shows the current buffer,
else point."
  (if (eq (window-buffer (selected-window)) (current-buffer))
      (window-start (selected-window))
    (point)))

(defun point-history--new-entry (kind)
  "Return a new entry of KIND at point in the current buffer."
  (point-history--make-entry
   :marker (point-marker)
   :file buffer-file-name
   :window-start (copy-marker (point-history--window-start))
   :kind kind))

(defun point-history--move-entry (entry kind)
  "Move ENTRY to point in the current buffer and set its KIND."
  (set-marker (point-history--entry-marker entry) (point))
  (set-marker (point-history--entry-window-start entry)
              (point-history--window-start))
  (setf (point-history--entry-file entry) buffer-file-name
        (point-history--entry-kind entry) kind))

(defun point-history--near-p (entry)
  "Return non-nil if ENTRY is near point in the current buffer.
Near means in the same buffer and at most `point-history-distance'
lines apart."
  (let ((marker (point-history--entry-marker entry)))
    (and (eq (marker-buffer marker) (current-buffer))
         (save-excursion
           (let ((a (min marker (point)))
                 (b (max marker (point))))
             (goto-char a)
             (<= (count-lines (line-beginning-position)
                              (progn (goto-char b) (line-beginning-position)))
                 point-history-distance))))))

(defun point-history--current-entry ()
  "Return the entry at `point-history--index', or nil."
  (nth point-history--index point-history--entries))

(defun point-history--limit-size ()
  "Drop the oldest entries beyond `point-history-size'."
  (let ((tail (nthcdr (1- (max 1 point-history-size))
                      point-history--entries)))
    (when tail
      (mapc #'point-history--release (cdr tail))
      (setcdr tail nil))))

(defun point-history--record-new (kind)
  "Record a new entry of KIND at point (rule 3).
Drop the entries newer than the index, reset the index to 0, end
the navigating state, remove an entry near point and put the new
entry at the front.  Store the removed entry in
`point-history--near-removed'.  Return the new entry."
  (let ((previous point-history--near-removed))
    (setq point-history--near-removed nil)
    (when previous
      (point-history--release-unless-listed (car previous))))
  (let ((dropped (cl-subseq point-history--entries 0 point-history--index)))
    (setq point-history--entries
          (nthcdr point-history--index point-history--entries)
          point-history--index 0
          point-history--navigating nil)
    (mapc #'point-history--release dropped))
  (let ((position (cl-position-if #'point-history--near-p
                                  point-history--entries)))
    (when position
      (let ((entry (nth position point-history--entries)))
        (setq point-history--near-removed (cons entry position)
              point-history--entries (delq entry point-history--entries)))))
  (let ((entry (point-history--new-entry kind)))
    (push entry point-history--entries)
    (point-history--limit-size)
    entry))

(defun point-history--activity (&optional kind)
  "Record activity of KIND at point in the current buffer.
KIND defaults to `activity'.  Apply the recording rules:
1. if point is near the current entry, move it to point;
2. else if the newest entry is a `visit' entry in the current
   buffer, move it to point;
3. else record a new entry (`point-history--record-new').
Return the entry that was moved or recorded."
  (let ((kind (or kind 'activity))
        (current (point-history--current-entry))
        (newest (car point-history--entries)))
    (cond
     ((and current (point-history--near-p current))
      (point-history--move-entry current kind)
      current)
     ((and newest
           (eq (point-history--entry-kind newest) 'visit)
           (eq (marker-buffer (point-history--entry-marker newest))
               (current-buffer)))
      (point-history--move-entry newest kind)
      newest)
     (t (point-history--record-new kind)))))

;;;; Recording

(defun point-history--recordable-p (&optional buffer)
  "Return non-nil if BUFFER (default: the current buffer) is recordable.
A recordable buffer is not a minibuffer, its major mode is not
derived from one in `point-history-ignored-modes', and it visits a
file unless `point-history-file-buffers-only' is nil."
  (with-current-buffer (or buffer (current-buffer))
    (and (not (minibufferp))
         (not (apply #'derived-mode-p point-history-ignored-modes))
         (or buffer-file-name (not point-history-file-buffers-only)))))

(defun point-history--navigation-command-p (command)
  "Return non-nil if COMMAND is a point-history navigation command.
Such commands have a non-nil `point-history-navigation' property."
  (and (symbolp command) (get command 'point-history-navigation)))

(defvar point-history--last-error nil
  "Text of the last error reported by the hooks or the timer.")

(defun point-history--report-error (err)
  "Show ERR with `message' unless it is the same as the last one."
  (let ((text (error-message-string err)))
    (unless (equal text point-history--last-error)
      (setq point-history--last-error text)
      (message "point-history: %s" text))))

(defmacro point-history--catching-errors (&rest body)
  "Run BODY and report any error instead of signaling it."
  (declare (indent 0) (debug t))
  `(condition-case err
       (progn ,@body)
     (error (point-history--report-error err))))

(defvar point-history--pre-buffer nil
  "The current buffer when the running command started.")

(defvar point-history--pre-tick nil
  "The character change tick of `point-history--pre-buffer'.")

(defun point-history--pre-command ()
  "Remember the buffer and its change tick before a command."
  (point-history--catching-errors
    (setq point-history--pre-buffer (current-buffer)
          point-history--pre-tick (buffer-chars-modified-tick))))

(defun point-history--command-activity-p ()
  "Return non-nil if the command that just ran counts as activity.
That is a copy command, or an edit command that changed the buffer it
started in and ended there."
  (or (memq this-command point-history-activity-commands)
      (and (eq point-history--pre-buffer (current-buffer))
           (not (eql point-history--pre-tick (buffer-chars-modified-tick)))
           (not (memq this-command point-history-ignored-edit-commands)))))

(defun point-history--check-navigating ()
  "End the navigating state if the selected window left the current entry.
That is the case when the window shows another buffer than the
current entry's, or its point is no longer near the current entry.
The index stays where it is."
  (let* ((window (selected-window))
         (buffer (window-buffer window))
         (current (point-history--current-entry)))
    (unless (and current
                 (eq buffer (marker-buffer
                             (point-history--entry-marker current)))
                 (with-current-buffer buffer
                   (save-excursion
                     (goto-char (window-point window))
                     (point-history--near-p current))))
      (setq point-history--navigating nil))))

(defun point-history--post-command ()
  "Record activity after a command if it was an edit or a copy.
Also remember whether the command was a navigation command and, after
another command, end the navigating state if point left the current
entry."
  (point-history--catching-errors
    (let ((navigation (point-history--navigation-command-p this-command)))
      ;; A navigation command that moved nowhere outside the navigating
      ;; state does not count, so the next one still applies the return
      ;; point rule.
      (setq point-history--last-navigation
            (and navigation point-history--navigating))
      (unless navigation
        (when (and (point-history--command-activity-p)
                   (eq (current-buffer) (window-buffer (selected-window)))
                   (point-history--recordable-p))
          (point-history--activity 'activity))
        (when point-history--navigating
          (point-history--check-navigating))))
    (setq point-history--pre-buffer nil
          point-history--pre-tick nil)))

(defun point-history--idle ()
  "Record reading at point of the selected window.
Do nothing while navigating or if its buffer is not recordable."
  (point-history--catching-errors
    (let* ((window (selected-window))
           (buffer (window-buffer window)))
      (when (and (not point-history--navigating)
                 (point-history--recordable-p buffer))
        (with-current-buffer buffer
          (save-excursion
            (goto-char (window-point window))
            (point-history--activity 'activity)))))))

;;;; Killed buffers

(defun point-history--all-entries ()
  "Return the history entries and the entry kept by the near rule."
  (if point-history--near-removed
      (cons (car point-history--near-removed) point-history--entries)
    point-history--entries))

(defun point-history--kill-buffer ()
  "Store the positions of the entries in the buffer being killed.
Run from `kill-buffer-hook'."
  (point-history--catching-errors
    (let ((buffer (current-buffer)))
      (dolist (entry (point-history--all-entries))
        (let ((marker (point-history--entry-marker entry)))
          (when (eq (marker-buffer marker) buffer)
            (setf (point-history--entry-position entry)
                  (marker-position marker)
                  (point-history--entry-start-position entry)
                  (marker-position (point-history--entry-window-start entry))
                  (point-history--entry-file entry)
                  (or buffer-file-name (point-history--entry-file entry)))))))))

(defun point-history--reattach (buffer file)
  "Point the markers of all detached entries of FILE into BUFFER.
Use the positions stored when their buffer was killed, `point-min'
if there are none, clamped to the size of BUFFER."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (dolist (entry (point-history--all-entries))
        (let ((marker (point-history--entry-marker entry)))
          (when (and (null (marker-buffer marker))
                     (equal (point-history--entry-file entry) file))
            (let ((position (min (max (or (point-history--entry-position entry)
                                          (point-min))
                                      (point-min))
                                 (point-max)))
                  (start (or (point-history--entry-start-position entry)
                             (point-history--entry-position entry)
                             (point-min))))
              (set-marker marker position buffer)
              (set-marker (point-history--entry-window-start entry)
                          (min (max start (point-min)) (point-max))
                          buffer)
              (setf (point-history--entry-position entry) nil
                    (point-history--entry-start-position entry) nil))))))))

(defun point-history--entry-live-p (entry)
  "Return non-nil if ENTRY is in a live buffer, reopening it if needed.
If the buffer of ENTRY was killed and its file exists, visit the file
and reattach all detached entries of that file to it."
  (let ((marker (point-history--entry-marker entry))
        (file (point-history--entry-file entry)))
    (or (marker-buffer marker)
        (when (and file (file-exists-p file))
          (point-history--reattach (find-file-noselect file) file)
          (marker-buffer marker)))))

(defun point-history--remove-entry (entry)
  "Remove ENTRY from the history and say so.
Adjust the index so that it still refers to the same entry."
  (let ((position (cl-position entry point-history--entries)))
    (when position
      (setq point-history--entries (delq entry point-history--entries))
      (when (< position point-history--index)
        (setq point-history--index (1- point-history--index)))
      (setq point-history--index
            (max 0 (min point-history--index
                        (1- (length point-history--entries)))))))
  (point-history--release entry)
  (let ((file (point-history--entry-file entry)))
    (if file
        (message "point-history: removed %s, file no longer exists" file)
      (message "point-history: removed entry, its buffer was killed"))))

;;;; Navigation

(defun point-history--apply-return-point ()
  "Insert a `return' entry at point unless the last command navigated.
On the first navigation command after another command, if point is
not near the current entry, insert a `return' entry at point just
before the current entry; the index then refers to it.

In a buffer that is not recordable no entry is inserted; return
non-nil in that case, meaning that point is away from the current
entry, so that going older should land on the current entry itself."
  (unless point-history--last-navigation
    (let ((current (point-history--current-entry)))
      (unless (and current (point-history--near-p current))
        (if (not (point-history--recordable-p))
            t
          (setq point-history--entries
                (append (cl-subseq point-history--entries
                                   0 point-history--index)
                        (cons (point-history--new-entry 'return)
                              (nthcdr point-history--index
                                      point-history--entries))))
          (point-history--limit-size)
          nil)))))

(defun point-history--search (direction &optional predicate from)
  "Return the index of the next usable entry in DIRECTION, or nil.
DIRECTION is 1 for older entries, -1 for newer ones.  The search
starts next to index FROM (default: the current index).  If PREDICATE
is non-nil, entries for which it returns nil are skipped; it is called
with the entry, whose buffer may have been killed.  An entry whose
buffer was killed is reopened (`point-history--entry-live-p'); if
that is not possible it is removed and the search goes on."
  (let ((i (+ (or from point-history--index) direction))
        (found nil))
    (while (and (not found) (>= i 0) (< i (length point-history--entries)))
      (let ((entry (nth i point-history--entries)))
        (cond
         ((and predicate (not (funcall predicate entry)))
          (setq i (+ i direction)))
         ((point-history--entry-live-p entry)
          (setq found i))
         (t
          (point-history--remove-entry entry)
          ;; Going older, the next entry has moved up to I; going
          ;; newer, it is still at I - 1.
          (when (< direction 0)
            (setq i (+ i direction)))))))
    found))

(defun point-history--show-entry (entry)
  "Show ENTRY in the selected window and go to its position.
Switch the buffer in the selected window, or use `pop-to-buffer' if
it is dedicated.  Restore the remembered window start if the
position is not visible."
  (let ((marker (point-history--entry-marker entry)))
    (if (window-dedicated-p (selected-window))
        (pop-to-buffer (marker-buffer marker))
      (switch-to-buffer (marker-buffer marker)))
    (goto-char marker)
    (let ((window (selected-window))
          (start (point-history--entry-window-start entry)))
      (when (and (eq (window-buffer window) (current-buffer))
                 (eq (marker-buffer start) (current-buffer))
                 (not (pos-visible-in-window-p (point) window)))
        (set-window-start window start)))))

(defun point-history--goto-index (index label)
  "Make INDEX the current entry, show it and echo LABEL and the position.
LABEL is a word like \"Back\", shown as \"LABEL <index+1>/<length>\"
if `point-history-message' is non-nil.  Start the navigating state.
If the entry cannot be reopened, remove it and return nil; otherwise
return non-nil."
  (let ((entry (nth index point-history--entries)))
    (if (not (point-history--entry-live-p entry))
        (progn (point-history--remove-entry entry) nil)
      (setq point-history--index index
            point-history--navigating t)
      (point-history--show-entry entry)
      (when point-history-message
        (message "%s %d/%d" label (1+ index) (length point-history--entries)))
      t)))

(defun point-history--navigate (direction label end-message &optional predicate)
  "Move to the next entry in DIRECTION for which PREDICATE holds.
DIRECTION, PREDICATE: see `point-history--search'.  Apply the return
point rule first (`point-history--apply-return-point').  LABEL is
passed to `point-history--goto-index'; END-MESSAGE is shown if there
is no such entry.  Going newer from index 0 shows END-MESSAGE
without inserting a return entry."
  (cond
   ((null point-history--entries)
    (message "No places recorded yet"))
   ((and (< direction 0) (= point-history--index 0))
    (message "%s" end-message))
   (t
    (let* ((away (point-history--apply-return-point))
           (from (if (and away (> direction 0))
                     (1- point-history--index)
                   point-history--index))
           (index (point-history--search direction predicate from)))
      (unless (and index (point-history--goto-index index label))
        (message "%s" end-message))))))

;;;###autoload
(defun point-history-back ()
  "Go back to the next older place in the point history.
On the first use after other commands, the place you leave is
remembered, so that `point-history-forward' comes back to it."
  (interactive)
  (point-history--navigate 1 "Back" "At oldest place"))
(put 'point-history-back 'point-history-navigation t)

;;;###autoload
(defun point-history-forward ()
  "Go forward to the next newer place in the point history."
  (interactive)
  (point-history--navigate -1 "Forward" "At newest place"))
(put 'point-history-forward 'point-history-navigation t)

(defvar point-history--timer nil
  "The idle timer that records reading, or nil.")

(defun point-history--cancel-timer ()
  "Cancel the idle timer if it is running."
  (when point-history--timer
    (cancel-timer point-history--timer)
    (setq point-history--timer nil)))

;;;###autoload
(define-minor-mode point-history-mode
  "Toggle recording of point history.
When enabled, places of activity are recorded so that you can move
back and forward through them.  Disabling the mode keeps the
history."
  :global t
  :group 'point-history
  (point-history--cancel-timer)
  (if point-history-mode
      (progn
        (add-hook 'pre-command-hook #'point-history--pre-command)
        (add-hook 'post-command-hook #'point-history--post-command)
        (add-hook 'kill-buffer-hook #'point-history--kill-buffer)
        (when point-history-idle-delay
          (setq point-history--timer
                (run-with-idle-timer point-history-idle-delay t
                                     #'point-history--idle))))
    (remove-hook 'pre-command-hook #'point-history--pre-command)
    (remove-hook 'post-command-hook #'point-history--post-command)
    (remove-hook 'kill-buffer-hook #'point-history--kill-buffer)))

(provide 'point-history)
;;; point-history.el ends here
