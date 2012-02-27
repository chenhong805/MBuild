(in-package #:sys.int)

(declaim (special *debug-io*
                  *standard-input*
                  *standard-output*))

(defparameter *debugger-depth* 0)

(defun sys.int::enter-debugger (condition)
  (let* ((*standard-input* *debug-io*)
	 (*standard-output* *debug-io*)
	 (debug-level *debugger-depth*)
	 (*debugger-depth* (1+ *debugger-depth*))
	 (restarts (compute-restarts))
	 (restart-count (length restarts)))
    (fresh-line)
    (write condition :escape nil :readably nil)
    (write-char #\Space)
    (write-char #\()
    (write (class-name (class-of condition)))
    (write-char #\))
    (fresh-line)
    (show-restarts restarts)
    (fresh-line)
    (backtrace)
    (loop
       (fresh-line)
       (write-string "Pick a restart# ")
       (let ((form (read)))
         (when (and (integerp form) (>= form 0) (< form restart-count))
           (invoke-restart-interactively (nth (- restart-count form 1) restarts)))))))

(defun show-restarts (restarts)
  (let ((restart-count (length restarts)))
    (write-string "Available restarts:")(terpri)
    (do ((i 0 (1+ i))
	 (r restarts (cdr r)))
	((null r))
      (write (- restart-count i 1))
      (write-char #\Space)
      (write (restart-name (car r)))
      (terpri))))

(defun backtrace ()
  (do ((fp (read-frame-pointer)
           (memref-unsigned-byte-64 fp 0)))
      ((= fp 0))
    (write-char #\Newline)
    (write-integer fp 16)
    (write-char #\Space)
    (let* ((fn (memref-t fp -2))
           (name (when (functionp fn) (function-name fn))))
      (write-integer (lisp-object-address fn) 16)
      (when name
        (write-char #\Space)
        (write name)))))

(defvar *traced-functions* '())
(defvar *trace-depth* 0)

(defun %trace (&rest functions)
  (dolist (fn functions)
    (when (and (not (member fn *traced-functions* :key 'car :test 'equal))
               (fboundp fn))
      (let ((name fn)
            (old-definition (fdefinition fn)))
      (push (list fn old-definition) *traced-functions*)
      (setf (fdefinition fn)
            (lambda (&rest args)
              (declare (dynamic-extent args)
                       (system:lambda-name trace-wrapper))
              (write *trace-depth* :stream *debug-io*)
              (write-string ": Enter " *debug-io*)
              (write name :stream *debug-io*)
              (write-char #\Space *debug-io*)
              (write args :stream *debug-io*)
              (terpri *debug-io*)
              (let ((result (multiple-value-list (let ((*trace-depth* (1+ *trace-depth*)))
                                                   (apply old-definition args)))))
                (write *trace-depth* :stream *debug-io*)
                (write-string ": Leave " *debug-io*)
                (write name :stream *debug-io*)
                (write-char #\Space *debug-io*)
                (write result :stream *debug-io*)
                (terpri *debug-io*)
                (values-list result)))))))
  *traced-functions*)

(defun %untrace (&rest functions)
  (if (null functions)
      (dolist (fn *traced-functions* (setf *traced-functions* '()))
        (setf (fdefinition (first fn)) (second fn)))
      (dolist (fn functions)
        (let ((x (assoc fn *traced-functions* :test 'equal)))
          (when x
            (setf *traced-functions* (delete x *traced-functions*))
            (setf (fdefinition (first x)) (second x)))))))
