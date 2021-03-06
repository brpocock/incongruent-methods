(in-package :incongruent-methods)

(defgeneric method-name-with-arity (name arity))

(defmethod method-name-with-arity ((name symbol) arity)
  (intern (format nil "~A/~A" name arity)
          (symbol-package name)))

(defmethod method-name-with-arity ((name list) arity)
  (list 'setf (method-name-with-arity (second name) arity)))

(defun method-parameter-name (x)
  (etypecase x
    (list (first x))
    (symbol x)))

(defun method-parameter-type (x)
  (etypecase x
    (list (second x))
    (t t)))

(defun method-lambda-list-arity (lambda-list)
  (length lambda-list))

(defun setf-method-p (name)
  (listp name))

;;;;

(defgeneric find-method-with-arity (name arity))
(defgeneric find-setf-method-with-arity (name arity))
(defgeneric add-method-with-arity (name arity))
(defgeneric remove-method-with-arity (name arity))

(defvar *methods-with-arity* (make-hash-table :test 'eq))
(defvar *setf-methods-with-arity* (make-hash-table :test 'eq))

(defun %add-method-with-arity (name arity table &optional setf)
  (let ((exist (gethash name table))
        (method-name
          (if setf
              (list 'setf (method-name-with-arity name arity))
              (method-name-with-arity name arity))))

    (unless exist
      (let ((new (make-hash-table :test 'eql)))
        (setf (gethash name table) new)
        (setf exist new)))

    (setf (gethash arity exist) method-name)))

(defmethod add-method-with-arity ((name symbol) arity)
  (%add-method-with-arity name arity *methods-with-arity*))

(defmethod add-method-with-arity ((name list) arity)
  (%add-method-with-arity (second name)
                          arity
                          *setf-methods-with-arity*
                          t))

(defun %find-method-with-arity (name arity table)
  (let ((ftable (gethash name table)))
    (when ftable
      (let ((arity-method (gethash arity ftable)))
        (when arity-method
          (fdefinition arity-method))))))

(defmethod find-method-with-arity ((name symbol) arity)
  (%find-method-with-arity name arity *methods-with-arity*))

(defmethod find-method-with-arity ((name list) arity)
  (%find-method-with-arity (second name)
                           arity
                           *setf-methods-with-arity*))

(defmethod find-setf-method-with-arity ((name symbol) arity)
  (%find-method-with-arity name arity *setf-methods-with-arity*))

(defun %remove-method-with-arity (name arity table)
  (let ((ftable (gethash name table)))
    (when ftable
      (remhash arity ftable))))

(defmethod remove-method-with-arity ((name symbol) arity)
  (%remove-method-with-arity name arity *methods-with-arity*))

(defmethod remove-method-with-arity ((name list) arity)
  (%remove-method-with-arity (second name)
                             arity
                             *setf-methods-with-arity*))

(defun dispatcher-compiler-macro (form)
  (flet ((make-form ()
           (cond ((eq (car form) 'funcall)
                  (if (and (listp (second form))
                           (member (car (second form))
                                   '(quote function)))
                      (destructuring-bind (funcall (fun-or-quote name)
                                           &rest args) form
                        `(,funcall (,fun-or-quote
                                    ,(method-name-with-arity
                                      name
                                      (method-lambda-list-arity args)))
                                   ,@args))
                      form))
                 (t (destructuring-bind (fun &rest args) form
                      `(,(method-name-with-arity
                          fun (method-lambda-list-arity args))
                        ,@args))))))
    #+debug-incongruent-methods
    (print form)
    #+debug-incongruent-methods
    (print (make-form))
    #-debug-incongruent-methods
    (make-form)))

(defun ensure-dispatcher (name)
  (let* ((func (lambda (&rest args)
                 #+debug-incongruent-methods
                 (format t "Generic dispatch: ~A~%" name)
                 (apply (find-method-with-arity
                         name
                         (method-lambda-list-arity args))
                        args))))

    (setf (fdefinition name) func)

    (setf (compiler-macro-function name)
          (lambda (form env)
            (declare (ignore env))
            (dispatcher-compiler-macro form)))))
;;;;

(defvar *generic-arity-functions* (make-hash-table :test 'equal))

(defgeneric incongruent-function-p (name))

(defmethod incongruent-function-p ((name t))
  (and (fboundp name)
       (gethash name *generic-arity-functions*)))

(defun ensure-generic-arity-function (name arity)
  (ensure-dispatcher name)
  (ensure-generic-function (method-name-with-arity name arity))
  (pushnew arity (gethash name *generic-arity-functions*)))

(defun list-incongruent-generic-functions (name)
  (mapcar (lambda (arity)
            (find-method-with-arity name arity))
          (gethash name *generic-arity-functions*)))

(defun list-incongruent-methods (name)
  (let ((gfs (list-incongruent-generic-functions name)))
    (loop :for gf :in gfs
          :append (closer-mop::generic-function-methods gf))))


;;;;

(defun remove-incongruent-function (name)
  (when (incongruent-function-p name)
    (fmakunbound name)
    (dolist (arity (gethash name *generic-arity-functions*))
      (fmakunbound (method-name-with-arity name arity))
      (remove-method-with-arity name arity))
    (remhash name *generic-arity-functions*)))

;;;;

(defun bad-lambda-list-p (lambda-list)
  (find-if (lambda (x)
             (member x '(&key &body &optional
                         &rest &whole &environment
                         &allow-other-keys &aux)))
           lambda-list))

(defun error-on-bad-lambda-list (name lambda-list)
  (when (bad-lambda-list-p lambda-list)
    (error "Lambda list not suitable for incongruent method ~S:~%~S"
           name
           lambda-list)))

(defmacro define-incongruent-method (name method-lambda-list
                                     &body body)

  (error-on-bad-lambda-list name method-lambda-list)
  (let* ((arity (method-lambda-list-arity method-lambda-list))
         (method-name (method-name-with-arity name arity)))
    `(progn
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (ensure-generic-arity-function ',name ,arity)
         (add-method-with-arity ',name ,arity))
       (defmethod ,method-name ,method-lambda-list
         ,@body))))

(pushnew :incongruent-methods *features*)
