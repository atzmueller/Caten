(in-package :caten/apis)

;; Compiles the ahead-of-time
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *jit-devices* `(:clang)) ;; TODO: Relocate
  (defparameter *vm-devices* `(:lisp)) ;; TODO: Relocate
  (defgeneric invoke-aot-function (device-id default-dtype default-order op &rest args))
  (defun create-blueprint-from-body (name dtype order lambda-list body &aux (*default-order* order))
    (let* ((*default-float* (if (caten/common.dtype:dtype/floatp dtype)    dtype *default-float*))
	   (*default-uint*  (if (caten/common.dtype:dtype/uintegerp dtype) dtype *default-uint*))
	   (*default-int*   (if (caten/common.dtype:dtype/integerp dtype)  dtype *default-int*))	   
	   (graph-f (compile nil `(lambda (,@(collect-initargs-names lambda-list)) ,@body)))
	   (outputs (multiple-value-list (apply graph-f (collect-initargs-names lambda-list))))
	   (name (intern (format nil "~(~a~)_~(~a~)_~(~a~)" name order dtype) "KEYWORD"))
	   (blueprint (let ((*device* :lisp)) (caten outputs :jit nil :name name))))
      (when (= 1 (ctx:getenv :STATIC_GENSYM))
	(caten/ajit:apply-static-gensym blueprint))	
      blueprint))
  (defmacro caten/defun[T] ((name cffi-prefix &key (dtypes) (orders `(:row :column))) lambda-list &body body)
    (declare (type string cffi-prefix))
    (let ((op-dispatcher (intern cffi-prefix "KEYWORD")))
      `(progn
	 ,@(loop
	     for order in orders
	     append
	     (loop
	       for dtype in dtypes
	       append
	       (loop
		 for *device* in `(,@*vm-devices* ,@*jit-devices*)
		 for jit-p = (find *device* *jit-devices*)
		 for blueprint = (create-blueprint-from-body cffi-prefix dtype order lambda-list body)
		 for avm = (if jit-p (caten/ajit:jit blueprint :backend *device*) blueprint)
		 append
		 `((defmethod invoke-aot-function ((device-id (eql ,*device*)) (default-dtype (eql ,dtype))
						   (order (eql ,order)) (op (eql ,op-dispatcher)) &rest args)
		     ;; TODO: dump avm
		     ;; (forward avm `(:a . ...) `(:b . ...))
		     )))))
	 (defun ,name (,@lambda-list)
	   ;; v one of float/int/uint mode only
	   (invoke-aot-function *device* :float32 *default-order* ,op-dispatcher ,@(collect-initargs-names lambda-list))))))
  
  (defmacro caten/defun[all] ((name cffi-prefix) lambda-list &body body)
    `(caten/defun[T] (,name ,cffi-prefix :dtypes (:float64 :float32 :float16 :uint64 :int64 :uint32 :int32 :uint16 :int16 :uint8 :int8)) (,@lambda-list) ,@body))
  (defmacro caten/defun[float] ((name cffi-prefix) lambda-list &body body)
    `(caten/defun[T] (,name ,cffi-prefix :dtypes (:float64 :float32 :float16)) (,@lambda-list) ,@body))
  (defmacro caten/defun[int] ((name cffi-prefix) lambda-list &body body)
    `(caten/defun[T] (,name ,cffi-prefix :dtypes (:int64 :uint32 :int32 :uint16 :int16 :uint8 :int8)) (,@lambda-list) ,@body))
  (defmacro caten/defun[uint] ((name cffi-prefix) lambda-list &body body)
    `(caten/defun[T] (,name ,cffi-prefix :dtypes (:uint64 :uint32 :uint16 :uint8)) (,@lambda-list) ,@body)))

;;(caten/defun[int] randn (size) (!randn `(,size)))

;; [TODO] Implement BLAS
;; should be separated from the main package though to avoid compilation error
(caten/defun[T] (axpy! "axpy" :dtypes (:float32)) (n froma toa bya fromb tob byb)
  (!add (!view (make-tensor `(,n)) `(,froma ,toa ,bya)) (!view (make-tensor `(,n)) `(,fromb ,tob ,byb)))) 