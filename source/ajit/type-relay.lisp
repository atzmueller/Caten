(in-package :caten/ajit)
;;
;;
;;
(defparameter *type-reporter* nil)
(defstruct (Type-Reporter
	    (:conc-name rp-)
	    (:constructor make-type-reporter ()))
  (id2buffer (make-hash-table :test #'eql))
  (seen nil :type list))

(defun map/type-of (type-reporter id)
  ;; Return: Buffer or number
  (declare (type type-reporter type-reporter)
	   (type (or number symbol) id))
  (if (numberp id)
      id
      (or (gethash id (rp-id2buffer type-reporter)) (error "map/type-of: ~a cannot be inferred from the graph" id))))

(defstruct (FakeArray
	    (:constructor make-fakearray (shape dtype initial-element)))
  (shape shape :type list)
  (dtype dtype :type dtype-t)
  (initial-element initial-element))

(defmethod %vm/allocate-buffer ((device-id (eql :relay-checker)) buffer)
  (let ((initial-value (if (eql (buffer-dtype buffer) :bool)
			   nil
			   (coerce 0 (dtype->lisp (buffer-dtype buffer))))))
    (if (= (buffer-nrank buffer) 0)
	(setf (buffer-value buffer) (make-fakearray nil (buffer-dtype buffer) initial-value))
	(setf (buffer-value buffer) (make-fakearray (buffer-shape buffer) (buffer-dtype buffer) initial-value)))
    buffer))

(defmethod %impl :around ((device-id (eql :relay-checker)) op graph node args)
  (let ((out-buffer (multiple-value-list (if (next-method-p) (call-next-method) (car args)))))
    (when *type-reporter*
      (loop for n in (node-writes node)
	    for o in out-buffer
	    do (assert (and (buffer-p o) (fakearray-p (buffer-value o)))
		       ()
		       "relay-checker: ~a should return a buffer whose value is fake-array, but got ~a" op o)
	       (setf (gethash n (rp-id2buffer *type-reporter*)) o)))
    (apply #'values out-buffer)))
(defmethod %impl ((device-id (eql :relay-checker)) op graph node args) (if (next-method-p) (call-next-method) (car args)))
(defmethod %impl ((device-id (eql :relay-checker)) (op (eql :Allocate)) graph node args)
  (multiple-value-bind (shape stride) (parse-allocate-node node args)
    (realize-buffer graph (node->id node) :shape1 shape :stride1 stride)))
(defmethod %impl ((device-id (eql :relay-checker)) (op (eql :view)) graph node args)
  (multiple-value-bind (shape v1 v2 v3 stride bc)
      (parse-view-node node args)
    (flet ((->number (x) (if (buffer-p x) (buffer-value x) x)))
      (let ((buffer (copy-buffer (car args))))
	(setf (buffer-shape buffer) (map 'list #'->number shape)
	      (buffer-stride buffer) (map 'list #'->number stride)
	      (buffer-views buffer)
	      (loop for i upfrom 0 below (length v1)
		    collect (list (->number (nth i v1)) (->number (nth i v2)) (->number (nth i v3)) (nth i bc)))
	      (buffer-nrank buffer) (length shape))
	buffer))))
(defmethod %impl ((device-id (eql :relay-checker)) (op (eql :Load)) graph node args)
  (let* ((tgt (car args))
	 (val (getattr node :value)))
    (let ((out (copy-buffer tgt)))
      (setf (buffer-value out) (make-fakearray nil (buffer-dtype out) val))
      out)))
(defmethod %impl ((device-id (eql :relay-checker)) (op (eql :WHERE)) graph node args) (second args))

(declaim (ftype (function (AVM) Type-Reporter) run-type-infer))
(defun run-type-infer (avm)
  (declare (type avm avm))
  (let ((*device* :relay-checker) (*type-reporter* (make-type-reporter)))
    (vm/forward avm) (vm/backward avm)
    *type-reporter*))