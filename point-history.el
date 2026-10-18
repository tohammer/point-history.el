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
If nil, recording of reading pauses is disabled."
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

;;;###autoload
(define-minor-mode point-history-mode
  "Toggle recording of point history.
When enabled, places of activity are recorded so that you can move
back and forward through them."
  :global t
  :group 'point-history
  ;; Hooks and timers are added here by later tasks.
  )

(provide 'point-history)
;;; point-history.el ends here
