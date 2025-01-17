(in-package :caten/nn)

(defclass AbstractOptimizer ()
  ((param :initarg :param :type Tensor :reader optimizer-param))
  (:documentation "
`AbstractOptimizer` is the base class for all optimizers. One `AbstractOptimizer` corresponds to one `Tensor` class with `:requires-grad=T`. `(optimizer-param optimizer)` to get the corresponding tensor.
"))

(defgeneric step-optimizer (optimizer) (:documentation "
```
(step-optimizer optimizer)
```

A trigger to update the parameters of the optimizer. It is not recommended to compile a new lazy function in this method because it will be called multiple times in the training loop. Use cacheable function instead (e.g.: `caten/defun`)
"))

(defun hook-optimizers (runtime hooker)
  "
```
(hook-optimizers runtime hooker)
```

This function is used to hook the optimizers in the recognised parameters in runtime-params. hooker is an function that takes one argument, which is the tensor that requires-grad=T, returns the AbstractOptimizer.

A list of created optimizers are returned.
"
  (declare (type caten/runtime:GraphRuntime runtime) (type function hooker))
  (map
   'list
   (compose
    #'(lambda (x) (assert (subtypep (class-of x) 'AbstractOptimizer) () "hook-optimizers: ~a is not an AbstractOptimizer!" x) x)
    hooker)
   (caten/runtime:runtime-params runtime)))

(caten/defun[float] (zero-grad-impl "zero_grad_impl") (n param)
  (!assign (make-tensor `(,n) :from param) (fconst 0)))

(defun zero-grad (optimizer)
  "
```
(zero-grad optimizer)
```
Fills the gradient of the optimizer with zeros.
"
  (declare (type AbstractOptimizer optimizer))
  (let ((grad (grad (optimizer-param optimizer))))
    (when (and grad (tensor-buffer grad))
      (zero-grad-impl (dtype-of grad) (apply #'* (shape grad)) grad))))

(defclass SGD (AbstractOptimizer)
  ((lr :initarg :lr))
  (:documentation "
Implements SGD Optimizer:

```math
Param_{new}\\gets{Param - Param_{grad}\\times{lr}}
```

where the initarg `:lr` is the learning rate.
"))

(defun SGD (&key (lr 1e-3))
  "
```
(SGD :lr 1e-3)
```
Returns a lambda function that takes one argument, which is the parameter tensor, and returns an instance of SGD optimizer.
"
  #'(lambda (x) (make-instance 'SGD :param x :lr lr)))

(caten/defun[float] (sgd-impl "sgd-impl") (n param grad lr)
  (!sub (make-tensor `(,n) :from param) (!mul (make-tensor `(,n) :from grad) (fconst lr)) :reduce t))

(defmethod step-optimizer ((optimizer SGD))
  (with-slots ((param param) (lr lr)) optimizer
    (sgd-impl (dtype-of param) (apply #'* (shape param)) param (grad param) lr)))
