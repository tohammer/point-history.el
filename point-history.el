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
(require 'subr-x)

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

(cl-defstruct (point-history--visit
               (:constructor point-history--make-visit)
               (:copier nil))
  "A file visit that is undone if it is left too soon.
ENTRY is the `visit' entry, BUFFER the visited buffer, TIME the
time of the visit (`point-history--now') and NEAR-REMOVED the value
of `point-history--near-removed' right after the visit was recorded."
  entry buffer time near-removed)

(defvar point-history--pending-visit nil
  "The last file visit, a `point-history--visit', or nil.
It is cleared when the selected window leaves the visited buffer.")

(defun point-history--pending-near-p (entry)
  "Return non-nil if ENTRY may be put back by the pending visit."
  (and point-history--pending-visit
       (eq entry (car (point-history--visit-near-removed
                       point-history--pending-visit)))))

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
    (when (and previous
               (not (point-history--pending-near-p (car previous))))
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
Activity in the buffer of the pending visit keeps that visit.
Return the entry that was moved or recorded."
  (when (and point-history--pending-visit
             (eq (point-history--visit-buffer point-history--pending-visit)
                 (current-buffer)))
    (point-history--end-visit))
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

(defvar point-history--pre-window-buffer nil
  "The buffer of the selected window when the running command started.
It is only set while the minibuffer is not active.")

(defun point-history--minibuffer-active-p ()
  "Return non-nil if a minibuffer is active."
  (or (> (minibuffer-depth) 0) (active-minibuffer-window)))

(defun point-history--pre-command ()
  "Remember the buffer, its change tick and the window buffer.
Do nothing while the minibuffer is active: commands run inside it
must not overwrite what the command reading from it remembered."
  (point-history--catching-errors
    (unless (point-history--minibuffer-active-p)
      (setq point-history--pre-buffer (current-buffer)
            point-history--pre-tick (buffer-chars-modified-tick)
            point-history--pre-window-buffer
            (window-buffer (selected-window))))))

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

;;;; File visits

(defun point-history--now ()
  "Return the current time in seconds."
  (float-time))

(defun point-history--own-command-p (command)
  "Return non-nil if COMMAND is a point-history command."
  (and command
       (symbolp command)
       (string-prefix-p "point-history-" (symbol-name command))))

(defun point-history--visit-target-p (buffer)
  "Return non-nil if showing BUFFER after the current command is a visit.
That is the case if `point-history-record-file-visits' is non-nil,
the command is not a point-history command and BUFFER is a
recordable buffer that visits a file."
  (and point-history-record-file-visits
       (not (point-history--own-command-p this-command))
       (buffer-file-name buffer)
       (point-history--recordable-p buffer)))

(defun point-history--record-visit (window)
  "Record a visit at point of WINDOW in its buffer (rule 3).
Make it the pending visit."
  (let ((buffer (window-buffer window)))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (window-point window))
        (let ((entry (point-history--record-new 'visit)))
          (setq point-history--pending-visit
                (point-history--make-visit
                 :entry entry
                 :buffer buffer
                 :time (point-history--now)
                 :near-removed point-history--near-removed)))))))

(defun point-history--undo-visit (visit)
  "Remove the entry of VISIT and put back the entry it removed.
The entry removed by the near rule is put back at its former
position, clamped to the length of the history, unless its buffer is
gone or it is in the history already.  Adjust the index so that it
still refers to the same entry; if that was the removed entry, keep
the index number, clamped to the history."
  (let* ((entry (point-history--visit-entry visit))
         (near-removed (point-history--visit-near-removed visit))
         (near (car near-removed))
         (index point-history--index)
         (current (nth index point-history--entries)))
    (setq point-history--entries (delq entry point-history--entries))
    (point-history--release entry)
    (when near
      (if (and (marker-buffer (point-history--entry-marker near))
               (not (memq near point-history--entries)))
          (let ((position (min (cdr near-removed)
                               (length point-history--entries))))
            (setq point-history--entries
                  (append (cl-subseq point-history--entries 0 position)
                          (cons near (nthcdr position
                                             point-history--entries)))))
        (point-history--release-unless-listed near)))
    (when (eq point-history--near-removed near-removed)
      (setq point-history--near-removed nil))
    (setq point-history--index
          (cond
           ((and current (not (eq current entry)))
            (cl-position current point-history--entries))
           (t (max 0 (min index (1- (length point-history--entries)))))))))

(defun point-history--end-visit ()
  "Clear the pending visit without undoing it.
Release the entry it could have put back unless that entry is in the
history or still kept in `point-history--near-removed'."
  (let ((near (car (point-history--visit-near-removed
                    point-history--pending-visit))))
    (setq point-history--pending-visit nil)
    (when (and near (not (eq near (car point-history--near-removed))))
      (point-history--release-unless-listed near))))

(defun point-history--leave-visit ()
  "Handle leaving the buffer of the pending visit and clear it.
Undo the visit if it lasted less than `point-history-visit-min-stay'
seconds and its entry is still a `visit' entry in the history.
Activity in the visited buffer clears the pending visit before (see
`point-history--activity'), so it is never undone after activity."
  (let* ((visit point-history--pending-visit)
         (entry (point-history--visit-entry visit)))
    (if (and (< (- (point-history--now) (point-history--visit-time visit))
                point-history-visit-min-stay)
             (memq entry point-history--entries)
             (eq (point-history--entry-kind entry) 'visit))
        (progn
          (setq point-history--pending-visit nil)
          (point-history--undo-visit visit))
      (point-history--end-visit))))

(defun point-history--check-buffer-change ()
  "Handle file visits after a command.
If the selected window shows another buffer than before the command,
handle leaving the pending visit (`point-history--leave-visit') and
record a visit if the new buffer qualifies (`point-history--visit-target-p').
Do nothing while the minibuffer is active."
  (unless (point-history--minibuffer-active-p)
    (let ((before point-history--pre-window-buffer)
          (window (selected-window)))
      (setq point-history--pre-window-buffer nil)
      (when (and before (not (eq before (window-buffer window))))
        (let ((buffer (window-buffer window)))
          (when (and point-history--pending-visit
                     (not (eq buffer (point-history--visit-buffer
                                      point-history--pending-visit))))
            (point-history--leave-visit))
          (when (point-history--visit-target-p buffer)
            (point-history--record-visit window)))))))

(defun point-history--post-command ()
  "Record activity after a command if it was an edit or a copy.
Also handle file visits (`point-history--check-buffer-change'),
remember whether the command was a navigation command and, after
another command, end the navigating state if point left the current
entry.  Do nothing while the minibuffer is active, so a command that
reads from it (e.g. `query-replace' or one run by \\[execute-extended-command])
is judged as a whole."
  (point-history--catching-errors
    (unless (point-history--minibuffer-active-p)
      (let ((navigation (point-history--navigation-command-p this-command)))
        ;; A navigation command that moved nowhere outside the navigating
        ;; state does not count, so the next one still applies the return
        ;; point rule.
        (setq point-history--last-navigation
              (and navigation point-history--navigating))
        (point-history--catching-errors
          (point-history--check-buffer-change))
        (unless navigation
          (when (and (point-history--command-activity-p)
                     (eq (current-buffer) (window-buffer (selected-window)))
                     (point-history--recordable-p))
            (point-history--activity 'activity))
          (when point-history--navigating
            (point-history--check-navigating))))
      (setq point-history--pre-buffer nil
            point-history--pre-tick nil))))

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

(defun point-history--navigate (direction label end-message
                                          &optional predicate adjust)
  "Move to the next entry in DIRECTION for which PREDICATE holds.
DIRECTION, PREDICATE: see `point-history--search'.  Apply the return
point rule first (`point-history--apply-return-point').  If ADJUST is
non-nil, call it with the index found and move to the index it
returns instead.  LABEL is passed to `point-history--goto-index';
END-MESSAGE is shown if there is no such entry.  Going newer from
index 0 shows END-MESSAGE without inserting a return entry."
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
      (when (and index adjust)
        (setq index (funcall adjust index)))
      (unless (and index (point-history--goto-index index label))
        (message "%s" end-message))))))

;;;; Filters

(defun point-history--entry-in-buffer-p (entry buffer)
  "Return non-nil if ENTRY belongs to BUFFER.
That is the case if its marker is in BUFFER or, when its buffer was
killed, if its file is the file BUFFER visits."
  (let ((mb (marker-buffer (point-history--entry-marker entry))))
    (if mb
        (eq mb buffer)
      (let ((file (buffer-file-name buffer)))
        (and file (equal file (point-history--entry-file entry)))))))

(defun point-history--same-buffer-p (a b)
  "Return non-nil if the entries A and B belong to the same buffer.
Entries of killed buffers are compared by file."
  (let ((ma (marker-buffer (point-history--entry-marker a)))
        (mb (marker-buffer (point-history--entry-marker b))))
    (if (and ma mb)
        (eq ma mb)
      (let ((file (point-history--entry-file a)))
        (and file (equal file (point-history--entry-file b)))))))

(defun point-history--this-buffer-predicate ()
  "Return a predicate that accepts entries of the current buffer."
  (let ((buffer (current-buffer)))
    (lambda (entry) (point-history--entry-in-buffer-p entry buffer))))

(defun point-history--other-buffer-predicate ()
  "Return a predicate that accepts entries not of the current buffer."
  (let ((buffer (current-buffer)))
    (lambda (entry)
      (not (point-history--entry-in-buffer-p entry buffer)))))

(defun point-history--newest-of-run (index)
  "Return the index of the newest entry of the run that contains INDEX.
A run is a series of adjacent entries of the same buffer."
  (let ((entry (nth index point-history--entries)))
    (while (and (> index 0)
                (point-history--same-buffer-p
                 entry (nth (1- index) point-history--entries)))
      (setq index (1- index)))
    index))

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

;;;###autoload
(defun point-history-back-file ()
  "Go back to the newest place of the next older file in the history.
Places in the current buffer are skipped."
  (interactive)
  (point-history--navigate 1 "Back" "No earlier file"
                           (point-history--other-buffer-predicate)))
(put 'point-history-back-file 'point-history-navigation t)

;;;###autoload
(defun point-history-forward-file ()
  "Go forward to the newest place of the next newer file in the history.
Places in the current buffer are skipped."
  (interactive)
  (point-history--navigate -1 "Forward" "No later file"
                           (point-history--other-buffer-predicate)
                           #'point-history--newest-of-run))
(put 'point-history-forward-file 'point-history-navigation t)

;;;###autoload
(defun point-history-back-in-file ()
  "Go back to the next older place in the current buffer."
  (interactive)
  (point-history--navigate 1 "Back" "No earlier place in this file"
                           (point-history--this-buffer-predicate)))
(put 'point-history-back-in-file 'point-history-navigation t)

;;;###autoload
(defun point-history-forward-in-file ()
  "Go forward to the next newer place in the current buffer."
  (interactive)
  (point-history--navigate -1 "Forward" "No later place in this file"
                           (point-history--this-buffer-predicate)))
(put 'point-history-forward-in-file 'point-history-navigation t)

;;;; List and remember

(defun point-history--candidate (entry position)
  "Return the completion candidate for ENTRY at 1-based POSITION.
It shows the position, the buffer name (the file name if the buffer
was killed), the line number and the trimmed text of the line.  For
a killed buffer the line number is \"?\" and the text is empty."
  (let* ((marker (point-history--entry-marker entry))
         (buffer (marker-buffer marker)))
    (if buffer
        (with-current-buffer buffer
          (save-excursion
            (save-restriction
              (widen)
              (goto-char marker)
              (format "%d %s:%d: %s" position (buffer-name)
                      (line-number-at-pos nil t)
                      (truncate-string-to-width
                       (string-trim (buffer-substring-no-properties
                                     (line-beginning-position)
                                     (line-end-position)))
                       80)))))
      (format "%d %s:?: " position
              (or (point-history--entry-file entry) "killed buffer")))))

(defun point-history--completion-table (candidates)
  "Return a completion table for CANDIDATES that keeps their order."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action candidates string predicate))))

;;;###autoload
(defun point-history-list ()
  "Choose a place from the point history and go to it.
The places are listed in history order, newest first."
  (interactive)
  (if (null point-history--entries)
      (message "No places recorded yet")
    (let* ((position 0)
           (alist (mapcar (lambda (entry)
                            (setq position (1+ position))
                            (cons (point-history--candidate entry position)
                                  entry))
                          point-history--entries))
           (choice (completing-read
                    "Place: "
                    (point-history--completion-table (mapcar #'car alist))
                    nil t))
           (entry (cdr (assoc choice alist))))
      (when entry
        (point-history--apply-return-point)
        (let ((index (cl-position entry point-history--entries)))
          (unless (and index (point-history--goto-index index "Go to"))
            (message "Place no longer in the history")))))))
(put 'point-history-list 'point-history-navigation t)

;;;###autoload
(defun point-history-remember ()
  "Record point as a place in the history now.
This works in any buffer except a minibuffer, whatever
`point-history-file-buffers-only' and `point-history-ignored-modes'
say, and does not wait for idle time."
  (interactive)
  (when (minibufferp)
    (user-error "Cannot remember a place in the minibuffer"))
  (point-history--activity 'activity)
  (when point-history-message
    (message "Place remembered")))

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
