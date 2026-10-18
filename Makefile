EMACS ?= emacs

.PHONY: all compile checkdoc test clean

all: compile checkdoc test

compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile point-history.el

checkdoc:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq checkdoc-verb-check-experimental-flag t)' \
	  --eval '(setq checkdoc-create-error-function (lambda (text start end &optional unfixable) (error "checkdoc: %s (at %s)" text start)))' \
	  --eval '(checkdoc-file "point-history.el")'

test:
	$(EMACS) -Q --batch -L . -l test/point-history-test.el \
	  -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc
