(in-package :blackbird)

(defvar *promise-keep-specials* '()
  "Names of special variables to be preserved during promise callbacks")

(defvar *promise-finish-hook* (lambda (finish-fn) (funcall finish-fn))
  "This is a function of one argument: a function of 0 args that is called to
   finish a promise. By default it just finishes the promise, but can be
   replaced to add a delay to the promise or finish it from another thread.")

(defclass promise ()
  ((name :accessor promise-name :initarg :name :initform nil
    :documentation "Lets a promise be named this is good for debugging.")
   (callbacks :accessor promise-callbacks :initform nil
    :documentation "A list that holds all callbacks associated with this promise.")
   (errbacks :accessor promise-errbacks :initform nil
    :documentation "A list that holds all errbacks associated with this promise.")
   (forwarded-promise :accessor promise-forward-to :initform nil
    :documentation "Can hold a reference to another promise, which will receive
                    callbacks and event handlers added to this one once set.
                    This allows a promise to effectively take over another promise
                    by taking all its callbacks/events.")
   (finished :accessor promise-finished :reader promise-finished-p :initform nil
    :documentation "Marks if a promise has been finished or not.")
   (errored :accessor promise-errored :reader promise-errored-p :initform nil
    :documentation "Marks if an error occured on this promise.")
   (error :accessor promise-error :initform nil
    :documentation "Holds an error value for this promise.")
   (values :accessor promise-values :initform nil
    :documentation "Holds the finished value(s) of the promise."))
  (:documentation
    "Defines a class which represents a value that MAY be ready sometime in the
     promise. Also supports attaching callbacks to the promise such that they will
     be called with the computed value(s) when ready."))

(defun wrap-callback (callback)
  (let ((all-vars *promise-keep-specials*)) ; avoid unneeded thread-unsafety
    (if (null all-vars)
        callback
        (let* ((bound (remove-if-not #'boundp all-vars))
               (vars (append bound (remove-if #'boundp all-vars)))
               (vals (mapcar #'symbol-value bound)))
          #'(lambda (&rest args)
              (progv vars vals (apply callback args)))))))

(defmethod print-object ((promise promise) s)
  (print-unreadable-object (promise s :type t :identity t)
    (when (promise-name promise)
      (format s "~_name: ~s " (promise-name promise)))
    ;(format s "~_callback(s): ~s " (length (promise-callbacks promise)))
    ;(format s "~_errback(s): ~s " (length (promise-errbacks promise)))
    (format s "~_finished: ~a " (promise-finished-p promise))
    (format s "~_errored: ~a " (promise-errored-p promise))
    (format s "~_forward: ~a" (not (not (promise-forward-to promise))))))

(defun make-promise (&key name)
  "Create a blank promise."
  (make-instance 'promise :name name))

(defun create-promise (create-fn &key name)
  "Returns a new promise, which can be finished/signaled via the given create-fn
   function, which takes exactly two values: a resolve function which is called
   with an arbitrary number of arguments and finishes the promise, and a reject
   function which takes a condition object and signals the condition on the
   promise."
  (let* ((promise (make-promise :name name))
         (resolve-fn (lambda (&rest vals) (apply 'finish (append (list promise) vals))))
         (reject-fn (lambda (condition) (signal-error promise condition))))
    (handler-case
      (funcall create-fn resolve-fn reject-fn)
      (condition (c) (signal-error promise c)))
    promise))

(defmacro with-promise ((resolve reject
                         &key (resolve-fn (gensym "resolve-fn"))
                              (reject-fn (gensym "reject-fn"))
                              name)
                         &body body)
  "Wraps create-promise in nicer syntax."
  `(create-promise 
     (lambda (,resolve-fn ,reject-fn)
       (declare (ignorable ,reject-fn))
       (flet ((,resolve (&rest args) (apply ,resolve-fn args))
              (,reject (condition) (funcall ,reject-fn condition)))
         ,@body))
     :name ,name))

(defun do-promisify (fn &key name)
  "Turns any value or set of values into a promise, unless a promise is passed
   in which case it is returned."
  (handler-case
    (let* ((vals (multiple-value-list (funcall fn)))
           (promise (car vals)))
      (if (promisep promise)
          promise
          (create-promise
            (lambda (resolve reject)
              (declare (ignore reject))
              (apply resolve vals))
            :name name)))
    (condition (e)
      (let ((promise (make-promise :name name)))
        (signal-error promise e)
        promise))))

(defmacro promisify (promise-gen)
  "Turns any value or set of values into a promise, unless a promise is passed
   in which case it is returned."
  `(do-promisify (lambda () ,promise-gen) :name ,(format nil "promisify: ~s" promise-gen)))

(defun promisep (promise)
  "Is this a promise?"
  (subtypep (type-of promise) 'promise))

(defun do-add-callback (promise cb)
  "Add a callback to a promise."
  (push cb (promise-callbacks promise)))

(defun do-attach-errback (promise errback)
  "Add an error handler for this promise."
  (let ((new-promise (make-promise)))
    (if (promisep promise)
        ;; return a promise that's fired with the return value of the error
        ;; handler
        (let ((forwarded-promise (lookup-forwarded-promise promise))
              (new-promise (make-promise)))
          (push (cons new-promise errback) (promise-errbacks forwarded-promise))
          (run-promise forwarded-promise))
        ;; pass along the given value
        (finish new-promise promise))
    new-promise))

(defun attach-errback (promise errback)
  "Add an error handler for this promise."
  (do-attach-errback promise (wrap-callback errback)))

(defun setup-promise-forward (promise-from promise-to)
  "Set up promise-from to send all callbacks, events, handlers, etc to the
   promise-to promise. This includes all current objects, plus objects that may be
   added later on. For instance, if you forward promise A to promise B, adding an
   event handler to promise A will then add it to promise B (assuming promise B has
   no current event handler). The same goes for callbacks as well, they will be
   added to the new promise-to if added to the promise-from."
  ;; a promise "returned" another promise. reattach the callbacks/errbacks from
  ;; the original promise onto the returned one
  (dolist (cb (reverse (promise-callbacks promise-from)))
    (do-add-callback promise-to cb))
  (dolist (errback (reverse (promise-errbacks promise-from)))
    (do-attach-errback promise-to errback))
  ;; mark the promise as forwarded so other parts of the system know to use the
  ;; new promise for various tasks.
  (setf (promise-forward-to promise-from) promise-to))

(defun lookup-forwarded-promise (promise)
  "This function follows forwarded promises until it finds the last in the chain
   of forwarding."
  (when (promisep promise)
    (loop while (promise-forward-to promise) do
      (setf promise (promise-forward-to promise))))
  promise)

(defun run-promise (promise)
  "Run all errorbacks if an error occured on the promise, or all callbacks if
   the promise is finished. If neither of those conditions are met, nothing
   happens."
  (if (promise-errored-p promise)
      (when (promise-errbacks promise)
        (let ((errbacks (reverse (promise-errbacks promise)))
              (error (promise-error promise)))
          (dolist (errback-entry errbacks)
            (let* ((promise (car errback-entry))
                   (errback (cdr errback-entry))
                   (res (funcall errback error)))
              (finish promise res))))
        (setf (promise-errbacks promise) nil))
      (when (promise-finished-p promise)
        (let ((callbacks (promise-callbacks promise))
              (values (promise-values promise)))
          (dolist (cb (reverse callbacks))
            (apply cb values)))
        (setf (promise-callbacks promise) nil)))
  promise)

(defun finish (promise &rest values)
  "Mark a promise as finished, along with all values it's finished with. If
   finished with another promise, forward the current promise to the new one."
  (unless (or (promise-finished-p promise)
              (promise-errored-p promise))
    (let ((new-promise (car values)))
      (funcall *promise-finish-hook*
        (lambda ()
          (cond ((promisep new-promise)
                 ;; set up the current promise to forward all callbacks/handlers/events
                 ;; to the new promise from now on.
                 (setup-promise-forward promise new-promise)
                 ;; run the new promise
                 (run-promise new-promise))
                (t
                 ;; just a normal finish, run the promise
                 (setf (promise-finished promise) t
                       (promise-values promise) values)
                 (run-promise promise)))))
      promise)))

(defun signal-error (promise condition)
  "Signal that an error has happened on a promise. If the promise has errbacks,
   they will be used to process the error, otherwise it will be stored until an
   errback is added to the promise."
  (unless (or (promise-errored-p promise)
              (promise-finished-p promise))
    (when (promisep promise)
      (let ((forwarded-promise (lookup-forwarded-promise promise)))
        (setf (promise-error forwarded-promise) condition)
        (setf (promise-errored forwarded-promise) t)
        (run-promise forwarded-promise)))))

(defun reset-promise (promise)
  "Clear out all callbacks/errbacks. Useful for halting a promise's execution."
  (let ((promise (lookup-forwarded-promise promise)))
    (setf (promise-callbacks promise) nil
          (promise-errbacks promise) nil
          (promise-error promise) nil
          (promise-values promise) nil
          (promise-finished promise) nil))
  promise)

(defun attach-cb (promise cb &key name)
  "Attach a callback to a promise. The promise must be the first value in a list
   of values (car promise-values) OR the promise-values will be apply'ed to cb."
  (let* ((promise (lookup-forwarded-promise promise))
         (cb-return-promise (make-promise :name name))
         (cb-wrapped (lambda (&rest args)
                       (let ((cb-return (multiple-value-list (apply cb args))))
                         (apply #'finish (append (list cb-return-promise)
                                                 cb-return))))))
    (attach-errback promise
      (lambda (e) (signal-error cb-return-promise e)))
    (do-add-callback promise (wrap-callback cb-wrapped))
    (run-promise promise)
    cb-return-promise))

(defmacro attach (promise-gen cb)
  "Macro wrapping attachment of callback to a promise (takes multiple values into
   account, which a simple function cannot)."
  `(attach-cb (promisify ,promise-gen) ,cb :name ,(format nil "attach: ~s" promise-gen)))

(defun do-catch (promise handler-fn)
  "Catch errors in the promise chain and run a handler function when caught."
  (with-promise (resolve reject :resolve-fn resolve-fn)
    (attach-errback promise
      (lambda (e)
        (handler-case
          (resolve (funcall handler-fn e))
          (condition (c) (reject c)))))
    (resolve promise)))

(defmacro catcher (promise-gen &rest handler-forms)
  "Catch errors in the promise chain and run a handler function when caught."
  `(do-catch (promisify ,promise-gen)
     (lambda (e)
       (typecase e
         ,@(loop for x in handler-forms collect
             (list (car x) `(let ((,(caadr x) e)) ,@(cddr x))))))))

(defun do-finally (promise finally-fn)
  "Run the finally-fn whether the given promise has a value or an error."
  (with-promise (resolve reject)
    (attach-errback promise
      (lambda (&rest _)
        (declare (ignore _))
        (resolve (funcall finally-fn))))
    (attach promise
      (lambda (&rest _)
        (declare (ignore _))
        (resolve (funcall finally-fn))))))
  
(defmacro finally (promise-gen &body body)
  "Run the body form whether the given promise has a value or an error."
  `(do-finally (promisify ,promise-gen) (lambda () ,@body)))
