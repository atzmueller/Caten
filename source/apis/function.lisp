(in-package :caten/apis)
;; Function creating a lazy computation node, should start with the prefix !.
;; TODO: Func is a syntax sugar for caten/air, we can reconstruct Func from Graph
(defclass Func () ((variables :initarg :variables :initform nil :accessor func-variables)))

(defgeneric lower (op &rest nodes)
  (:documentation "Lowers the Func into a list of `caten/air:node`. This should return caten/air:graph."))
(defgeneric forward (op &rest tensors)
  (:documentation "Create the type for the Tensor after computation. Be mindful of its lazy evaluation nature; do not perform the actual computation."))
(defgeneric backward (op &optional prev-grad)
  (:documentation "Create the graph for backward of op given prev-grad. Return: `(values input_1.grad input_2.grad ...)`.
save-for-backward is determined automatically, so you do not have to consider about in-place operation."))

(defmethod forward :around ((op Func) &rest tensors)
  (let ((outs (handler-bind
		  ((error
		     #'(lambda (c) (error 'caten-forward-error :op op :inputs tensors :c c))))
		(multiple-value-list (call-next-method)))))
    (setf (func-variables op) tensors)
    (dolist (o outs)
      (assert (tensor-p o) ())
      (setf (tensor-variables o) tensors
	    (tensor-op o) op))
    (apply #'values outs)))
;; ~~ differentiable ops ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(defclass IdentityNode (Func) nil)
(defmethod forward ((op IdentityNode) &rest tensors) (st "A[~] -> A[~]" (tensors)))
(defmethod backward ((op IdentityNode) &optional prev-grad) (values prev-grad))
(defmethod lower ((op IdentityNode) &rest inputs) (with-context (_ (%store (car inputs) (car inputs) :reduction t))))
(defun !identity (tensor) (forward (make-instance 'IdentityNode) tensor))

(defclass Allocate (Func)
  ((buffer :initarg :buffer :type Tensor :accessor alloc-buffer)
   (initial-element :initarg :initial-element :initform nil :accessor alloc-initial-element)
   (id :initform nil :accessor alloc-id)))
(defmethod forward ((op Allocate) &rest tensors) (declare (ignore tensors)) (alloc-buffer op))
(defmethod backward ((op Allocate) &optional dout)
  (let ((buff (alloc-buffer op)))
    (when (tensor-requires-grad buff)
      ;; op.grad += buff
      (let ((id (gensym "ACC")))
	(setf (alloc-id op) id)
	(values (!add (tensor-grad buff) dout :reduce t :id id))))))
(defmethod lower ((op Allocate) &rest inputs)
  (declare (ignore inputs))
  (let ((buff (alloc-buffer op))
	(nodes))
    (flet ((->lower (obj) ;; If the shape includes a tensor, it also needs to be lowered
	     (if (or (numberp obj) (symbolp obj)) obj
		 (let ((g (%tensor->aasm obj)))
		   (and (push g nodes) (car (last (graph-nodes g))))))))
      (let ((g
	      (with-context
		(s (map 'list #'->lower (tensor-shape buff)))
		(a (%make-tensor s :dtype (tensor-dtype buff) :order (tensor-order buff) :id (tensor-id buff)))
		(a (when (alloc-initial-element op) (%load a (alloc-initial-element op)))))))
	(push g nodes)
	(apply #'make-graph (apply #'append (map 'list #'graph-nodes (reverse nodes))))))))

(defclass View (Func)
  ((views :initarg :views :type list :accessor view-views)
   (subscripts :initarg :subscripts :accessor view-subscripts)
   (broadcast-mode :initarg :broadcast-mode :accessor view-broadcast-mode)
   (nrank :initarg :nrank :accessor view-nrank)))
(defmethod backward ((op View) &optional dout)
  (with-slots ((nrank nrank) (broadcast-mode broadcast-mode) (views views) (subscripts subscripts)) op
    (let* ((base (clone-like (car (func-variables op)))))
      (if broadcast-mode
	  (let* ((base (apply #'!view base subscripts))
		 (dout (!add base (!contiguous dout) :reduce t)))
	    (apply #'!view dout (map 'list #'(lambda (x) (if (and (listp x) (eql (car x) :~)) 0 t)) subscripts)))
	  (apply #'!view-from-base (!move (apply #'!view base subscripts) dout) (loop for s in (shape base) collect `(0 ,s)))))))
(defmethod lower ((op View) &rest inputs)
  (let ((nrank (view-nrank op))
	(bs (car (func-variables op))))
    (flet ((subseq1p (x frm &optional to) (subseq x (1+ frm) (if to (1+ to)))))
      (with-context
	  (viewed (%view (car inputs)
			 (subseq1p inputs 0 nrank) (subseq1p inputs nrank (* 2 nrank))
			 (subseq1p inputs (* 2 nrank) (* 3 nrank)) (subseq1p inputs (* 3 nrank) (* 4 nrank))
			 (map 'list #'viewrange-broadcast (view-views op))
			 (let ((base-shape (subseq1p inputs (* 4 nrank) (* 5 nrank)))
			       (stride     (subseq1p inputs (* 5 nrank))))
			   (or stride (%stride base-shape (tensor-order bs))))))))))
(defun !view (base &rest subscripts) (make-view-internal base subscripts))
(defun !view-from-base (base &rest subscripts) (make-view-internal base subscripts :allow-merge nil))

(defclass Permute (Func)
  ((nrank :initarg :nrank :accessor permute-nrank)
   (order :initarg :order :accessor permute-order)))
(defmethod permute-list ((op Permute) list)
  (loop for nth in (permute-order op)
	collect (nth nth list)))
(defmethod forward ((op Permute) &rest inputs)
  (let ((x (car inputs))
	(order (permute-order op)))
    (assert (= (length order) (ndim (car inputs)) (length (intersection (range 0 (ndim (car inputs))) order)))
	    ()
	    "Permute: order is not a valid permutation, getting ~a.~%axes are chosen from ~a" order (range 0 (ndim (car inputs))))
    (make-tensor (permute-list op (shape x)) :dtype (dtype-of x) :order (order x) :views (and (tensor-views x) (permute-list op (tensor-views x))))))
(defmethod forward :around ((op Permute) &rest inputs)
  (let* ((x (call-next-method))
	 (views (tensor-views x)))
    (setf (tensor-variables x)
	  (append
	   (tensor-variables x)
	   (if views
	       (append
		(map 'list (compose #'sfold #'vrange-size) views)
		(map 'list (compose #'sfold #'viewrange-from) views)
		(map 'list (compose #'sfold #'viewrange-to) views)
		(map 'list (compose #'sfold #'viewrange-by) views)
		(map 'list (compose #'sfold #'viewrange-size) (tensor-views (car inputs))))
	       (append
		;; visible shape
		(map 'list (compose #'sfold #'->iconst) (shape x))
		;; upfrom
		(map 'list #'(lambda (_) _ (iconst 0)) (shape x))
		;; below
		(map 'list (compose #'sfold #'->iconst) (shape x))
		;; by
		(map 'list #'(lambda (_) _ (iconst 1)) (shape x))
		;; original shape
		(map 'list (compose #'sfold #'->iconst) (shape (car inputs))))))
	  (func-variables op) (tensor-variables x))
    x))
(defmethod backward ((op Permute) &optional dout) (!permute dout (permute-order op)))
(defmethod lower ((op Permute) &rest inputs)
  (let* ((bs (car (func-variables op)))
	 (nrank (ndim bs)))
    (flet ((subseq1p (x frm &optional to) (subseq x (1+ frm) (if to (1+ to)))))
      (with-context
	  (viewed (%view (car inputs)
			 (subseq1p inputs 0 nrank)
			 (subseq1p inputs nrank (* 2 nrank))
			 (subseq1p inputs (* 2 nrank) (* 3 nrank))
			 (subseq1p inputs (* 3 nrank) (* 4 nrank))
			 (permute-list op (map 'list #'viewrange-broadcast (tensor-views bs)))
			 (permute-list op (%stride (subseq1p inputs (* 4 nrank) (* 5 nrank)) (tensor-order bs)))))))))

(defun !permute (tensor order) (forward (make-instance 'Permute :order order) tensor))
(defun !t (tensor)
  (let ((range (range 0 (ndim tensor)))
	(n (ndim tensor)))
    (setf (nth (- n 2) range) (nth (- n 1) range)
	  (nth (- n 1) range) (1- (nth (- n 2) range)))
    (!permute tensor range)))
(defun !contiguous (x &key (force nil))
  (declare (type tensor x))
  (if (or force (tensor-views x))
      (let ((out (make-tensor (tensor-shape x) :dtype (tensor-dtype x) :order (tensor-order x))))
	(!move out x))
      x))

(defclass Reshape (Func)
  ((shape-bf :initarg :shape-bf :accessor reshape-shape-bf)
   (shape-af :initarg :shape-af :accessor reshape-shape-af)
   (order    :initarg :order    :accessor reshape-order)))
(defmethod forward ((op Reshape) &rest tensors)
  (when (and (every #'numberp (reshape-shape-bf op)) (every #'numberp (reshape-shape-af op)))
    (assert (= (apply #'* (reshape-shape-bf op)) (apply #'* (reshape-shape-af op)))
	    ()
	    "Assertion Failed: Cannot reshape from ~a to ~a. The number of total elements should correspond."
	    (reshape-shape-bf op) (reshape-shape-af op)))
  (make-tensor (reshape-shape-af op) :dtype (tensor-dtype (car tensors)) :order (tensor-order (car tensors))))
(defmethod forward :around ((op Reshape) &rest tensors)
  (let ((out-tensor (call-next-method)))
    (setf (tensor-variables out-tensor)
	  (append (list (car tensors))
		  (loop for s in (reshape-shape-af (tensor-op out-tensor))
			collect (if (tensor-p s) s (iconst s))))
	  (func-variables (tensor-op out-tensor)) (tensor-variables out-tensor))
    out-tensor))
(defmethod backward ((op Reshape) &optional prev-grad) (!reshape prev-grad (reshape-shape-bf op)))
(defmethod lower ((op Reshape) &rest nodes)
  (let ((tensor (car (func-variables op))))
    (with-context
      (a (if (null (reshape-shape-bf op))
	     (%move (%make-tensor `(1) :dtype (tensor-dtype tensor) :order (tensor-order tensor)) (car nodes))
	     (if (null (reshape-shape-af op))
		 (%load (%salloc :dtype (tensor-dtype tensor)) (car nodes))
		 (car nodes))))
      (a (when (reshape-shape-af op) (%reshape a (cdr nodes) :order (reshape-order op)))))))
(defun !reshape (x shape)
  (declare (type tensor x) (type list shape))
  (forward (make-instance 'Reshape :shape-bf (tensor-shape x) :shape-af shape :order (tensor-order x)) x))
(defun !uprank (x n)
  (declare (type tensor x) (type (integer 0) n))
  (!reshape x (append (loop for i upfrom 0 below n collect 1) (tensor-shape x))))
(defun !repeat (x &rest repeats)
  (let* ((base-shape (append (loop repeat (- (length repeats) (ndim x)) collect 1) (shape x)))
	 (new-shape (loop for s in (shape x) append (list 1 s)))
	 (expand-shape (loop for r in repeats for b in base-shape append (list `(:~ ,r) t)))
	 (final-shape (loop for s in (shape x) for r in repeats collect (!mul (->iconst s) (->iconst r)))))
    (apply #'!view (!reshape (!contiguous (apply #'!view (!reshape x new-shape) expand-shape)) final-shape) (loop for f in final-shape collect t))))
(defun !expand (x shape)
  (multiple-value-bind (view-index reshape-to) (apply #'values (pad-left (shape x) shape))
    (let ((x (if (= (ndim x) (length shape)) x (!reshape x reshape-to))))	  
      (apply #'!view x (map 'list #'(lambda (x y) (if (eql x y) t `(:~ ,x))) view-index reshape-to)))))
;; ~~ binary ops ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(defclass Move (Func) nil)
(defmethod forward ((op Move) &rest tensors) (st "A[~] B[~] -> A[~]" (tensors)))
(defmethod backward ((op Move) &optional dout) (values dout dout))
(defmethod lower ((op Move) &rest inputs)
  (multiple-value-bind (a b) (apply #'values inputs)
    (with-context (out (%move a b)))))
(defun !move (a b) (declare (type tensor a b)) (forward (make-instance 'Move) a b))

(defclass Add (Func)
  ((reduce :initarg :reduce :initform nil :accessor func-reduce)
   (id :initarg :id :initform nil :accessor func-id)))
(defmethod forward ((op Add) &rest tensors) (st "A[~] B[~] -> A[~]" (tensors)))
(defmethod backward ((op Add) &optional dout) (values dout dout))
(defmethod lower ((op Add) &rest inputs)
  (multiple-value-bind (a b) (apply #'values inputs)
    (with-context (out (%add a b :reduction (func-reduce op) :id (or (func-id op) (gensym "BID")))))))

(defclass Mul (Func) ((reduce :initarg :reduce :initform nil :accessor func-reduce)))
(defmethod forward ((op Mul) &rest tensors) (st "A[~] B[~] -> A[~]" (tensors)))
(defmethod backward ((op Mul) &optional dout)
  (multiple-value-bind (x y) (apply #'values (func-variables op))
    (values (!mul y dout) (!mul x dout))))
(defmethod lower ((op Mul) &rest inputs)
  (multiple-value-bind (a b) (apply #'values inputs)
    (with-context (out (%mul a b :reduction (func-reduce op))))))

(defclass MaxOp (Func) ((reduce :initarg :reduce :initform nil :accessor func-reduce)))
(defmethod forward ((op MaxOp) &rest tensors) (st "A[~] B[~] -> A[~]" (tensors)))
(defmethod backward ((op MaxOp) &optional dout)
  (warn "WIP: MaxOp"))
(defmethod lower ((op MaxOp) &rest inputs)
  (multiple-value-bind (a b) (apply #'values inputs)
    (with-context (out (%max a b :reduction (func-reduce op))))))

(defclass GCDOp (Func) ((reduce :initarg :reduce :initform nil :accessor func-reduce)))
(defmethod forward ((op GCDOp) &rest tensors) (st "A[~] B[~] -> A[~]" (tensors)))
(defmethod backward ((op GCDOp) &optional dout) (values nil nil))
(defmethod lower ((op GCDOp) &rest inputs)
  (multiple-value-bind (a b) (apply #'values inputs)
    (with-context (out (%gcd a b :reduction (func-reduce op))))))
;; Unary
(defclass Neg (Func) nil)
(defmethod forward ((op Neg) &rest tensors) (st "A[~] -> A[~]" (tensors)))
(defmethod backward ((op Neg) &optional dout) (values (!neg dout)))
(defmethod lower ((op Neg) &rest inputs) (with-context (a (%neg (car inputs)))))

(defclass SinNode (Func) nil)
(defmethod forward ((op SinNode) &rest tensors) (st "A[~] -> A[~]" (tensors)))
(defmethod backward ((op SinNode) &optional dout) (values (!cos dout)))
(defmethod lower ((op SinNode) &rest inputs) (with-context (a (%sin (car inputs)))))
(defun !sin (x) (forward (make-instance 'SinNode) x))

(defclass ExpNode (Func) nil)
(defmethod forward ((op ExpNode) &rest tensors) (st "A[~] -> A[~]" (tensors)))
(defmethod backward ((op ExpNode) &optional dout) (values (!mul (car (func-variables op)) dout)))
(defmethod lower ((op ExpNode) &rest inputs)
  (with-context
    (m (%mul (car inputs) (%fconst (/ (log 2)) :dtype (dtype-of (car (func-variables op))))))
    (a (%exp2 m))))

(defclass LogNode (Func) nil)
(defmethod forward ((op LogNode) &rest tensors) (st "A[~] -> A[~]" (tensors)))
(defmethod backward ((op LogNode) &optional dout) (values (!mul dout (!recip (car (func-variables op))))))
(defmethod lower ((op LogNode) &rest inputs)
  (with-context
    (a (%log2 (car inputs)))
    (b (%mul a (%fconst (log 2) :dtype (dtype-of (car (func-variables op))))))))

(defclass SqrtNode (Func) nil)
(defmethod forward ((op SqrtNode) &rest tensors) (st "A[~] -> A[~]" (tensors)))
(defmethod backward ((op SqrtNode) &optional prev-grad) (!mul prev-grad (!recip (!mul (!sqrt (car (func-variables op))) (!const prev-grad 2)))))
(defmethod lower ((op SqrtNode) &rest inputs) (with-context (a (%sqrt (car inputs)))))

(defun !exp (x) (forward (make-instance 'ExpNode) x))
(defun !log (x) (forward (make-instance 'LogNode) x))
(defun !sqrt (x) (forward (make-instance 'SqrtNode) x))

(defclass Recip (Func) nil)
(defmethod forward ((op Recip) &rest tensors) (st "A[~] -> A[~]" (tensors)))
(defmethod backward ((op Recip) &optional dout)
  (let ((ret (!recip (car (func-variables op)))))
    (values (!mul (!mul (!neg dout) ret) ret)))) ;; -dout / x^2
(defmethod lower ((op Recip) &rest inputs) (with-context (a (%recip (car inputs)))))

(defclass Cast (Func)
  ((dtype-frm :initarg :dtype-frm :accessor cast-dtype-frm)
   (dtype-to :initarg :dtype-to   :accessor cast-dtype-to)))
(defmethod forward ((op Cast) &rest tensors) (st "A[~] B[~] -> A[~]" (tensors)))
(defmethod backward ((op Cast) &optional prev-grad) (values prev-grad (!cast prev-grad (cast-dtype-frm op))))
(defmethod lower ((op Cast) &rest inputs) (with-context (a (%cast (first inputs) (second inputs) (cast-dtype-to op)))))
(defun !cast (x dtype &key (out (make-tensor (tensor-shape x) :dtype dtype :order (tensor-order x))))
  (declare (type tensor x out) (type dtype-t dtype))
  (forward (make-instance 'Cast :dtype-frm (tensor-dtype x) :dtype-to dtype) out x))
;; ~~ wrappers ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(declaim (ftype (function (Tensor Tensor &key (:reduce boolean) (:id t)) (values Tensor &optional)) !add))
(declaim (ftype (function (Tensor Tensor &key (:reduce boolean)) (values Tensor &optional)) !sub !mul !div !maximum !minimum))
(defun !add (a b &key (reduce nil) (id nil)) (apply #'forward (make-instance 'Add :reduce reduce :id id) (broadcast-elwise a b)))
(defun !mul (a b &key (reduce nil)) (apply #'forward (make-instance 'Mul :reduce reduce) (broadcast-elwise a b)))
(defun !sub (a b &key (reduce nil)) (!add a (!neg b) :reduce reduce))
(defun !div (a b &key (reduce nil)) (!mul a (!recip b) :reduce reduce))
(defun !maximum (a b &key (reduce nil)) (apply #'forward (make-instance 'MaxOp :reduce reduce) (broadcast-elwise a b)))
(defun !minimum (a b &key (reduce nil)) (!neg (!maximum (!neg a) (!neg b) :reduce reduce)))
(defun !gcd (a b &key (reduce nil)) (apply #'forward (make-instance 'GCDOp :reduce reduce) (broadcast-elwise a b)))
(defun !lcm (a b) (!div (!mul a b) (!gcd a b)))
(macrolet ((def (name b) `(defun ,name (&rest args) (reduce ,b args))))
  (def !+ #'!add)
  (def !- #'!sub)
  (def !* #'!mul)
  (def !/ #'!div))
(macrolet ((def (name cls)
	     `(progn
		(declaim (ftype (function (Tensor) (values Tensor &optional)) ,name))
		(defun ,name (x) (declare (type Tensor x)) (forward (make-instance ',cls) x)))))
  (def !neg Neg)
  (def !recip Recip))
(declaim (ftype (function (Tensor) (values Tensor &optional)) !signum !abs))
(defun !signum (x)
  (flet ((->const (val) (make-scalar val :dtype (tensor-dtype x))))
    (let ((zeros (!where (!eq x (->const 0)) (->const 0) (->const 1))))
      (!mul zeros (!where (!>= x (->const 0)) (->const 1) (->const -1))))))
(defun !abs (x) (!mul (!signum x) x))

;; ~~ Compare Ops ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(macrolet ((def (name cls aop)
	     `(progn
		(defclass ,cls (Func) nil)
		(defmethod forward ((op ,cls) &rest tensors) (st "OUT[~] A[~] B[~] -> OUT[~]" (tensors)))
		(defmethod lower ((op ,cls) &rest inputs)
		  (with-context (out (,aop nil nil (nth 1 inputs) (nth 2 inputs) :out (nth 0 inputs)))))
		(defun ,name (x y)
		  (declare (type Tensor x y))
		  (multiple-value-bind (x y)
		      (bc "A[~] B[~] -> A[~] B[~]" (x y))
		    (forward (make-instance ',cls) (make-tensor (tensor-shape x) :dtype :bool :order (tensor-order x)) x y))))))
  (def !<  LessThan     %<)
  (def !<= LessEqual    %<=)
  (def !>  GreaterThan  %>)
  (def !>= GreaterEqual %>=)
  (def !eq TensorEqual %=)
  (def !neq NotEqual %!=))
;; ~~ TernaryOps ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(defclass Where (Func) nil)
(defmethod forward ((op Where) &rest tensors)
  (assert (eql (tensor-dtype (nth 1 tensors)) (tensor-dtype (nth 2 tensors)))
	  ()
	  "Assertion Failed: A.dtype != B.dtype")
  (st "MAP[~] A[~] B[~] -> A[~]" (tensors)))
(defmethod backward ((op Where) &optional prev-grad)
  (multiple-value-bind (c) (apply #'values (func-variables op))
    (values
     nil
     (!where c prev-grad (zeros-like prev-grad))
     (!where c (zeros-like prev-grad) prev-grad))))
(defmethod lower ((op Where) &rest inputs) (with-context (out (%where (nth 0 inputs) (nth 1 inputs) (nth 2 inputs)))))
(defun !where (condition x y)
  (declare (type Tensor condition x y))
  (multiple-value-bind (condition x y)
      (bc "C[~] X[~] Y[~] -> C[~] X[~] Y[~]" (condition x y))
    (forward (make-instance 'Where) condition x y)))

(declaim (ftype (function (Tensor (or number symbol)) (values Tensor &optional)) !const))
(defun !const (tensor value)
  "Creates a scalar tensor"
  (declare (type tensor tensor) (type (or number symbol) value))
  (make-scalar value :dtype (dtype-of tensor)))

;; ~~ Proceed ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(defclass ProceedNode (Func) nil)
(defmethod forward ((op ProceedNode) &rest inputs) (st "A[~] -> A[~]" (inputs)))
(defmethod backward ((op ProceedNode) &optional prev-grad) prev-grad)
(defmethod lower ((op ProceedNode) &rest inputs)
  (declare (ignore inputs))
  (with-context (_ (%make-tensor (%shape (shape (car (func-variables op)))) :dtype (dtype-of (car (func-variables op))) :order (order (car (func-variables op))) :id (tensor-id (car (func-variables op))) :from (tensor-buffer (car (func-variables op)))))))
(defun %apply-proceed (proceed-output)
  "Proceed-Output[Tensor] - a realized tensor."
  (declare (type tensor proceed-output))
  (let* ((detached-tensor (st "A[~] -> A[~]" (proceed-output))))
    (setf (tensor-buffer detached-tensor) (tensor-buffer proceed-output))
    (let ((output (forward (make-instance 'ProceedNode) detached-tensor)))
      (setf (tensor-buffer output) (tensor-buffer detached-tensor))
      output)))