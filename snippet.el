;;; snippet.el --- yasnippet's engine distilled  -*- lexical-binding: t; -*-

;; Copyright (C) 2013  João Távora

;; Author: João Távora <joaotavora@gmail.com>
;; Keywords: convenience

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;; Commentary:

;;

;;; Code:

(require 'cl-lib)


;;; the define-snippet macro and its helpers
;;;
(defvar snippet--sym-obarray (make-vector 100 nil))

(defun snippet--make-field-sym (field-name)
  (intern (format "field-%s" field-name) snippet--sym-obarray))

(defun snippet--make-mirror-sym (mirror-name source-field-name)
  (intern (format "mirror-%s-of-%s" mirror-name
                  source-field-name)
          snippet--sym-obarray))

(defun snippet--make-exit-sym ()
  (intern "exit" snippet--sym-obarray))

(defun snippet--make-transform-lambda (transform-form)
  `(lambda (field-string field-empty-p)
     ,transform-form))

(defun snippet--make-lambda (eval-form)
  `#'(lambda (region-string)
       ,eval-form))

(defun snippet--canonicalize-form (form)
  (pcase form
    ((or `&field `(&field))
     `(&field ,(cl-gensym "auto") nil))
    (`(&field ,name)
     `(&field ,name nil))
    (`(&eval ,_)
     form)
    (`(&eval . ,_)
     (error "provide only one form after &eval in %S" form))
    (`(&mirror ,name)
     `(&mirror ,name (&transform field-string)))
    (`(&mirror ,_ (&transform ,_))
     form)
    (`(&field ,_ (,(or `&transform `&eval) ,_))
     form)
    (`(,(or `&mirror `&field) ,_ (,(or `&transform `&eval) ,_ . (,extra)))
     (error "expected one form after &eval or &transform in %S, you have %d"
            form (1+ (length extra))))
    (`(,(or `&mirror `&field) ,name ,_ . (,extra))
     (error "expected one form after '%S' in %S, you have %d"
            name
            form (1+ (length extra))))
    (`(&field ,name (&nested . ,more-forms))
     `(&field ,name (&nested ,@(mapcar #'snippet--canonicalize-form
                                       more-forms))))
    (`(&mirror ,name ,expr)
     `(&mirror ,name (&transform ,expr)))

    (`(&field ,name ,expr)
     `(&field ,name (&eval ,expr)))

    (`(&exit ,expr)
     `(&exit (&eval ,expr)))
    ((or `&exit `(&exit))
     `(&exit (&eval nil)))
    ((pred atom)
     `(&eval ,form))
    ((pred consp)
     `(&eval ,form))
    (t
     (error "invalid snippet form %s" form))))

(defun snippet--unfold-forms (forms &optional parent-sym)
  (cl-loop for form in forms
           collect (append form
                           `((&parent ,parent-sym)))
           append (pcase form
                    (`(&field ,name (&nested . ,subforms))
                     (snippet--unfold-forms subforms
                                            (snippet--make-field-sym name))))))

(defun snippet--define-body (body)
  "Does the actual work for `define-snippet'"
  (let ((unfolded (snippet--unfold-forms
                   (mapcar #'snippet--canonicalize-form body)))
        all-objects exit-object)
    `(let* (,@(loop for form in unfolded
                    append (pcase form
                             (`(&field ,name ,_expr (&parent ,parent))
                              `((,(snippet--make-field-sym name)
                                 (snippet--make-field :parent ,parent
                                                      :name ',name))))))
            (region-string (and (region-active-p)
                                (buffer-substring-no-properties
                                 (region-beginning)
                                 (region-end)))))
       (let* (,@(loop
                 for form in unfolded
                 with mirror-idx = 0
                 with sym
                 with prev-sym
                 append
                 (pcase form
                   (`(&field ,name ,expr (&parent ,_parent))
                    (setq sym (snippet--make-field-sym name))
                    `((,sym (snippet--insert-field
                             ,sym
                             ,prev-sym
                             ,(pcase expr
                                (`(&eval ,form)
                                 `(funcall ,(snippet--make-lambda form)
                                           region-string)))))))
                   (`(&mirror ,name (&transform ,transform) (&parent ,parent))
                    (setq sym (snippet--make-mirror-sym
                               (cl-incf mirror-idx) name))
                    `((,sym (snippet--make-and-insert-mirror
                             ,parent
                             ,prev-sym
                             ,(snippet--make-field-sym name)
                             ',transform))))
                   (`(&exit (&eval ,form) (&parent ,parent))
                    (when exit-object
                      (error "too many &exit forms given"))
                    (setq sym (snippet--make-exit-sym)
                          exit-object sym)
                    `((,sym (snippet--make-and-insert-exit
                             ,parent
                             ,prev-sym
                             ,(and form
                                   `(funcall ,(snippet--make-lambda form)
                                             region-string))))))
                   (`(&eval ,form (&parent ,parent))
                    `((,(cl-gensym "constant-")
                       (snippet--insert-constant
                        ,parent
                        (funcall ,(snippet--make-lambda form)
                                 region-string))))))
                 when sym do
                 (push sym all-objects)
                 (setq prev-sym sym)
                 (setq sym nil)))
         (snippet--activate-snippet (list ,@all-objects))))))


(cl-defmacro define-snippet (name () &rest snippet-forms)
  "Define NAME as a snippet-inserting function.

NAME's function definition is set to a function with no arguments
that inserts the snippet's components at point.

Each form in SNIPPET-FORMS, inserted at point in order, can be:

* A cons (&field FIELD-NAME FIELD-DEFAULT) definining a snippet
  field. A snippet field can be navigated to using
  `snippet-next-field' and `snippet-prev-field'. FIELD-NAME is
  optional and used for referring to the field in mirror
  transforms. FIELD-DEFAULT is also optional and used for
  producing a string that populates the field's default value at
  snippet-insertion time.

  FIELD-DEFAULT can thus be a string literal, a lisp form
  returning a string, or have the form (&nested SUB-FORM ...)
  where each SUB-FORM is evaluated recursively according to the
  rules of SNIPPET-FORMS.

  FIELD-DEFAULT can additionally also be (&transform
  FIELD-TRANSFORM) in which case the string value produced by
  FIELD-TRANSFORM is used for populating not only the field's
  default value, but also the field's value after each command
  while the snippet is alive.

* A cons (&mirror FIELD-NAME MIRROR-TRANSFORM) defining a mirror
  of the field named FIELD-NAME. MIRROR-TRANSFORM is optional and
  is called after each command while the snippet is alive to
  produce a string that becomes the mirror text.

* A string literal or a lisp form CONSTANT evaluated at
  snippet-insertion time and producing a string that is a part of
  the snippet but constant while the snippet is alive.

* A form (&exit EXIT-DEFAULT), defining the point within the
  snippet where point should be placed when the snippet is
  exited. EXIT-DEFAULT is optional and is evaluated at
  snippet-insertion time to produce a string that remains a
  constant part of the snippet while it is alive, but is
  automatically selected when the snippet is exited.

The forms CONSTANT, FIELD-DEFAULT, MIRROR-TRANSFORM,
FIELD-TRANSFORM and EXIT-DEFAULT are evaluated with the variable
`region-string' set to the text of the buffer selected at
snippet-insertion time. If no region was selected the value of
this variable is the empty string..

The forms MIRROR-TRANSFORM and FIELD-TRANSFORM are evaluated with
the variable `field-string' set to the text contained in the
corresponding field. If the field is empty, this variable is the
empty string and the additional variable `field-empty-p' is t. If
these forms return nil, they are considered to have returned the
empty string.

If the form CONSTANT returns nil or the empty string, it is
considered to have returned a single whitespace.

ARGS is an even-numbered property list of (KEY VAL) pairs. Its
meaning is not decided yet"
  (declare (debug (&define name sexp &rest snippet-form)))
  `(defun ,name ()
     ,(snippet--define-body snippet-forms)))

(def-edebug-spec snippet-form
  (&or
   ("&mirror" sexp def-form)
   ("&field" sexp &or ("&nested" &rest snippet-form) def-form)
   def-form))

(defun make-snippet (forms)
  "Same as `define-snippet', but return an anonymous function."
  `(lambda () ,(snippet--define-body forms)))


;;; Snippet mechanics
;;;

(cl-defstruct snippet--object
  start end parent next prev (buffer (current-buffer)))

(cl-defstruct (snippet--field (:constructor snippet--make-field)
                              (:include snippet--object))
  name
  (mirrors '())
  (modified-p nil))

(cl-defstruct (snippet--mirror (:constructor snippet--make-mirror)
                               (:include snippet--object))
  source
  (transform nil))

(cl-defstruct (snippet--exit (:constructor snippet--make-exit)
                             (:include snippet--object)))

(defun snippet--call-with-inserting-object (object prev fn)
  (when prev
    (cl-assert (null (snippet--object-next prev)) nil
               "previous object already has another sucessor")
    (setf (snippet--object-next prev) object))
  (setf (snippet--object-start object)
        (let ((parent (snippet--object-parent object)))
          (cond ((and parent
                      (= (point) (snippet--object-start parent)))
                 (snippet--object-start parent))
                ((and prev
                      (= (point) (snippet--object-end prev)))
                 (snippet--object-end prev))
                (t
                 (point-marker)))))
  (funcall fn)
  (setf (snippet--object-end object)
        (point-marker))
  (when (snippet--object-parent object)
    (setf (snippet--object-end
           (snippet--object-parent object))
          (snippet--object-end object)))
  (snippet--open-object object 'close)
  object)

(defmacro snippet--inserting-object (object prev &rest body)
  (declare (indent defun) (debug (sexp sexp &rest form)))
  `(snippet--call-with-inserting-object ,object ,prev #'(lambda () ,@body)))

(defun snippet--insert-field (field prev default)
  (snippet--inserting-object field prev
    (when default
      (insert default))))

(defun snippet--make-and-insert-mirror (parent prev source transform)
  (let ((mirror (snippet--make-mirror
                 :parent parent
                 :prev prev
                 :source source
                 :transform (snippet--make-transform-lambda transform))))
    (snippet--inserting-object mirror prev
      (pushnew mirror (snippet--field-mirrors source)))))

(defun snippet--make-and-insert-exit (parent prev constant)
  (let ((exit (snippet--make-exit :parent parent :prev prev)))
   (snippet--inserting-object exit prev
     (when constant
       (insert constant)))))

(defun snippet--insert-constant (parent constant)
  (when constant
    (insert constant))
  (when parent
    (setf (snippet--object-end parent) (point-marker))))

(defun snippet--object-empty-p (object)
  (= (snippet--object-start object)
     (snippet--object-end object)))

(defun snippet--objects-adjacent-p (prev next)
  (eq (snippet--object-end prev)
      (snippet--object-start next)))

(defun snippet--open-object (object &optional close-instead)
  (let ((stay (cons (snippet--object-start object)
                    (cl-loop for o = object then prev
                             for prev = (snippet--object-prev o)
                             while (and prev
                                        (snippet--objects-adjacent-p prev o)
                                        (snippet--object-empty-p prev))
                             collect (snippet--object-start prev))))
        (push (cons (snippet--object-end object)
                    (cl-loop for o = object then next
                             for next = (snippet--object-next o)
                             while (and next
                                        (snippet--objects-adjacent-p o next)
                                        (snippet--object-empty-p next))
                             collect (snippet--object-end next)))))
    (when close-instead
      (if (snippet--object-empty-p object)
          (setq stay (append stay push)
                push nil)
        (cl-rotatef stay push)))
    (mapc #'(lambda (m) (set-marker-insertion-type m nil)) stay)
    (mapc #'(lambda (m) (set-marker-insertion-type m t)) push)))

(defun snippet--call-with-current-object (object fn)
  (unwind-protect
      (progn
        (snippet--open-object object)
        (funcall fn))
    (snippet--open-object object 'close)))

(defmacro snippet--with-current-object (object &rest body)
  (declare (indent defun) (debug t))
  `(snippet--call-with-current-object ,object #'(lambda () ,@body)))

(defun snippet--update-mirror (mirror)
  (snippet--with-current-object mirror
    (delete-region (snippet--object-start mirror)
                   (snippet--object-end mirror))
    (save-excursion
      (goto-char (snippet--object-start mirror))
      (let ((field-string (snippet--field-string (snippet--mirror-source mirror))))
        (insert (or (funcall (snippet--mirror-transform mirror)
                             field-string
                             (string= "" field-string))
                    ""))))))

(defvar snippet--field-overlay nil)

(defun snippet--move-to-field (field)
  (goto-char (snippet--object-start field))
  (move-overlay snippet--field-overlay
                (point)
                (snippet--object-end field))
  (overlay-put snippet--field-overlay 'snippet--field field))

(defun snippet--update-field-mirrors (field)
  (mapc #'snippet--update-mirror (snippet--field-mirrors field))
  (when (snippet--object-parent field)
    (snippet--update-field-mirrors (snippet--object-parent field))))

(defun snippet--field-overlay-changed (overlay after? beg end
                                               &optional pre-change-len)
  ;; there's a slight (apparently innocuous) bug here: if the overlay has
  ;; zero-length, both `insert-in-front' and `insert-behind' modification hooks
  ;; are called
  ;;
  (let* ((field (overlay-get overlay 'snippet--field))
         (inhibit-modification-hooks t))
    (cond (after?
           ;; field clearing: if we're doing an insertion and the field hasn't
           ;; been modified yet, we're going to delete previous contents and
           ;; leave just the newly inserted text.
           ;;
           (when (and (not (snippet--field-modified-p field))
                      (= beg (snippet--field-start field))
                      (zerop pre-change-len))
             ;; At first glance, we could just delete the region between `end'
             ;; and the `field's end, but that wouldn't empty any child fields
             ;; that `field' might have, since that child's markers, albeit
             ;; closed, may will have legitimately moved to accomodate the
             ;; insertion. So we save the text, delete the entire field contents
             ;; and insert it back in place. The child's markers will move
             ;; together.
             ;;
             (let ((saved (buffer-substring beg end)))
               (delete-region (snippet--object-start field)
                              (snippet--object-end field))
               (insert saved)))
           (setf (snippet--field-modified-p field) t)
           (snippet--update-field-mirrors field)
           (move-overlay overlay
                         (snippet--object-start field)
                         (snippet--object-end field)))
          (t
           (snippet--open-object field)))))

(defun snippet--field-string (field)
  (let ((start (snippet--object-start field))
        (end (snippet--object-end field)))
    (buffer-substring-no-properties start end)))


;;; Interactive
;;;
(defgroup snippet nil
  "Customize snippet features"
  :group 'convenience)

(defface snippet-field-face
  '((t (:inherit 'region)))
  "Face used to highlight the currently active field of a snippet")

(defvar snippet-field-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<tab>")       'snippet-next-field)
    (define-key map (kbd "S-<tab>")     'snippet-prev-field)
    (define-key map (kbd "<backtab>")   'snippet-prev-field)
    map)
  "The active keymap while a live snippet is being navigated.")

(defun snippet--field-skip-p (field)
  (let ((parent (snippet--field-parent field)))
    (and parent
         (snippet--object-empty-p field)
         (snippet--field-modified-p parent))))

(defun snippet-next-field (&optional prev)
  (interactive)
  (let* ((field (overlay-get snippet--field-overlay 'snippet--field))
         (sorted (overlay-get snippet--field-overlay 'snippet--fields))
         (sorted (if prev (reverse sorted) sorted))
         (target (if field
                     (cadr (cl-remove-if #'snippet--field-skip-p
                                         (memq field sorted)))
                   (first sorted))))
    (if target
        (snippet--move-to-field target)
      (let ((exit (overlay-get snippet--field-overlay
                               'snippet--exit)))
        (goto-char (if (markerp exit)
                       exit
                       (snippet--object-start exit))))
      (snippet-exit-snippet))))

(defun snippet-prev-field ()
  (interactive)
  (snippet-next-field t))

(defun snippet-exit-snippet (&optional reason)
  (delete-overlay snippet--field-overlay)
  (message "snippet exited%s"
           (or (and reason
                    (format " (%s)" reason))
               "")))


;;; Main
;;;
(defvar snippet--debug nil)
;; (setq snippet--debug t)
;; (setq snippet--debug nil)

(defun snippet--activate-snippet (objects)
  (let ((mirrors (cl-sort (cl-remove-if-not #'snippet--mirror-p objects)
                          #'(lambda (p1 p2)
                              (cond ((not p2) t)
                                    ((not p1) nil)))
                          :key #'snippet--object-parent))
        (fields (cl-sort (cl-remove-if-not #'snippet--field-p objects)
                         #'(lambda (n1 n2)
                             (cond ((not (integerp n2)) t)
                                   ((not (integerp n1)) nil)
                                   (t (< n1 n2))))
                         :key #'snippet--field-name))
        (exit (or
               (cl-find-if #'snippet--exit-p objects)
               (let ((marker (point-marker)))
                 (prog1 marker
                   (set-marker-insertion-type marker t))))))
    (mapc #'snippet--update-mirror mirrors)
    (setq snippet--field-overlay
          (let ((overlay (make-overlay (point) (point) nil nil t)))
            (overlay-put overlay 'snippet--objects objects)
            (overlay-put overlay 'snippet--fields  fields)
            (overlay-put overlay 'snippet--exit    exit)
            (overlay-put overlay 'face '           snippet-field-face)
            (overlay-put overlay
                         'modification-hooks
                         '(snippet--field-overlay-changed))
            (overlay-put overlay
                         'insert-in-front-hooks
                         '(snippet--field-overlay-changed))
            (overlay-put overlay
                         'insert-behind-hooks
                         '(snippet--field-overlay-changed))
            (overlay-put overlay
                         'keymap
                         snippet-field-keymap)
            overlay))
    (snippet-next-field)
    (add-hook 'post-command-hook 'snippet--post-command-hook t)))

(defun snippet--post-command-hook ()
  (cond ((and snippet--field-overlay
              (overlay-buffer snippet--field-overlay))
         (cond ((or (< (point)
                       (overlay-start snippet--field-overlay))
                    (> (point)
                       (overlay-end snippet--field-overlay)))
                (snippet-exit-snippet "point left snippet")
                (remove-hook 'post-command-hook 'snippet--post-command-hook t))
               (snippet--debug
                (snippet--debug-snippet snippet--field-overlay))))
        (snippet--field-overlay
         ;; snippet must have been exited for some other reason
         ;;
         (remove-hook 'post-command-hook 'snippet--post-command-hook t))))


;;; Debug helpers
;;;
(defun snippet--describe-object (object)
  (with-current-buffer (snippet--object-buffer object)
    (format "from %s to %s covering \"%s\""
            (snippet--object-start object)
            (snippet--object-end object)
            (buffer-substring-no-properties
             (snippet--object-start object)
             (snippet--object-end object)))))

(defun snippet--describe-field (field)
  (let ((active-field
         (overlay-get snippet--field-overlay 'snippet--field)))
    (with-current-buffer (snippet--object-buffer field)
      (format "field %s %s%s"
              (snippet--field-name field)
              (snippet--describe-object field)
              (if (eq field active-field)
                  " *active*"
                "")))))

(defun snippet--describe-mirror (mirror)
  (with-current-buffer (snippet--object-buffer mirror)
    (format "mirror of %s %s"
            (snippet--field-name (snippet--mirror-source mirror))
            (snippet--describe-object mirror))))

(defun snippet--describe-exit (exit)
  (with-current-buffer (snippet--object-buffer exit)
    (format "exit %s" (snippet--describe-object exit))))

(defun snippet--debug-snippet (field-overlay)
  (with-current-buffer (get-buffer-create "*snippet-debug*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (cl-loop for object in
               (cl-sort (cl-copy-list
                         (overlay-get field-overlay 'snippet--objects)) #'<
                         :key #'snippet--object-start)
               do (cond ((snippet--field-p object)
                         (insert (snippet--describe-field object) "\n"))
                        ((snippet--mirror-p object)
                         (insert (snippet--describe-mirror object) "\n"))
                        ((snippet--exit-p object)
                         (insert (snippet--describe-exit object) "\n")))))
    (display-buffer (current-buffer))))

(provide 'snippet)

;; Local Variables:
;; coding: utf-8
;; whitespace-style: (face lines-tail)
;; whitespace-line-column: 80
;; fill-column: 80
;; End:
;; snippet.el ends here
