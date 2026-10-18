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

(provide 'point-history-test)
;;; point-history-test.el ends here
