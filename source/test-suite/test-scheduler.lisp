(in-package :caten/test-suite)
;; Tests caten/codegen/scheduler.lisp
(defun schedule-with-vars (&rest tensors)
  (ctx:with-contextvar (:BACKEND "LISP")
    (let ((runtime (apply #'caten tensors)))
      (caten/codegen/shape-inference:run-type-infer runtime)
      (caten/codegen/rewriting-rules:apply-rewriting-rules runtime)
      (values (graph-schedule (runtime-graph runtime)) runtime))))

(defun gather-kernels (schedule-graph)
  (loop for node in (graph-nodes schedule-graph)
        if (getattr node :jitable)
          collect node))

(defun check-kernel (schedule-graph n-count &key (expect-failure nil))
  (if expect-failure
      (ng (= n-count (length (gather-kernels schedule-graph))) (format nil "[Expect Failure] Scheduled ~a, expected ~a" (length (gather-kernels schedule-graph)) n-count))
      (ok (= n-count (length (gather-kernels schedule-graph))) (format nil "Scheduled ~a, expected ~a" (length (gather-kernels schedule-graph)) n-count))))
;; ~~ Testing reduction ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(deftest test-double-reduction-separated
  (testing "Reduction with different axes are not fused into a single kernel"
    (let ((schedule (schedule-with-vars (!sum (!sum (make-tensor `(10 10)) :axis 0 :keepdims t) :axis 1 :keepdims t))))
      (check-kernel schedule 2)))
  (testing "Reduction with different axes are not fused into a single kernel"
    (let ((schedule (schedule-with-vars (!sum (!sum (make-tensor `(10 10)) :axis 0 :keepdims t) :axis 1 :keepdims t))))
      (check-kernel schedule 2))))

(deftest test-no-extra-loop-after-out-complex
  (multiple-value-bind (schedule runtime)
      (schedule-with-vars (!matmul (make-tensor `(64 64)) (!gelu (!matmul (make-tensor `(64 64)) (make-tensor `(64 64))))))
    (check-kernel schedule 2)
    (caten/codegen/expr-cache:with-expr-cache ()
      (dolist (item (gather-kernels schedule))
        (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
          (ok (= 3 (count :FOR bp :key #'node-type)) (format nil "Expected 3 loops, got ~a" (count :FOR bp :key #'node-type))))))))

(deftest test-no-extra-loop-matmul-ln-matmul
  (multiple-value-bind (schedule runtime)
      (schedule-with-vars (!matmul (make-tensor `(64 64)) (!layer-norm (!matmul (make-tensor `(64 64)) (make-tensor `(64 64))) `(64 64))))
    (check-kernel schedule 3)
    (caten/codegen/expr-cache:with-expr-cache () ;; Test LayerNorm is not fused with Matmul
      (loop for item in (gather-kernels schedule)
            for count in `(4 3 3) do ;; LayerNorm -> Matmul -> Matmul
              (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
                (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type))))))))

(deftest test-symbolic-loop-merge-dims
  (testing "B and 10 is merged:"
    (multiple-value-bind (schedule runtime)
        (with-inference-mode ()
          (schedule-with-vars (!add (call (Embedding 10 10) (make-tensor `(b 10))) (call (Embedding 10 10) (make-tensor `(b 10))))))
      (check-kernel schedule 1)
      (caten/codegen/expr-cache:with-expr-cache ()
        (loop for item in (gather-kernels schedule)
              for count in `(3) do
                (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
                  (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type))))))))
  (testing "Embedding but batch size is a tensor"
    (multiple-value-bind (schedule runtime)
        (with-inference-mode ()
          (let ((b (!add (iconst 'm) (iconst 'n))) (c (!add (iconst 'm) (iconst 'n))))
            (schedule-with-vars (!add (call (Embedding 10 10) (make-tensor `(,b 10))) (call (Embedding 10 10) (make-tensor `(,c 10)))))))
      (check-kernel schedule 1)
      (caten/codegen/expr-cache:with-expr-cache ()
        (loop for item in (gather-kernels schedule)
              for count in `(3) do
                (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
                  (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type))))))))
  (testing "Elementwise is 1D"
    (multiple-value-bind (schedule runtime) (schedule-with-vars (!relu (make-tensor `(a b c d))))
      (check-kernel schedule 1)
      (caten/codegen/expr-cache:with-expr-cache ()
        (loop for item in (gather-kernels schedule)
              for count in `(1) do
                (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
                  (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type))))))))
  (testing "Softmax Batch=Tensor"
    (multiple-value-bind (schedule runtime) (schedule-with-vars (!softmax (make-tensor `(,(!add (iconst 'n) (iconst 's)) n s))))
      (check-kernel schedule 1)
      (caten/codegen/expr-cache:with-expr-cache ()
        (loop for item in (gather-kernels schedule)
              for count in `(4) do
                (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
                  (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type))))))))
  (testing "Matmul Batch=Tensor"
    (multiple-value-bind (schedule runtime) (schedule-with-vars (!matmul (make-tensor `(,(!add (iconst 'a) (iconst 'b)) 512 256)) (make-tensor `(256 1024))))
      (check-kernel schedule 1)
      (caten/codegen/expr-cache:with-expr-cache ()
        (loop for item in (gather-kernels schedule)
              for count in `(3) do
                (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
                  (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type)))))))))

(deftest test-serialize-reduction-loop
  (with-no-grad
    (testing "Serialized Reductions should belong to the same loop. (not creating a new inner loop!)"
      (testing "Add(Matmul, Matmul)"
        (multiple-value-bind (schedule runtime)
            (schedule-with-vars (!add (!matmul (make-tensor `(64 64)) (make-tensor `(64 64)))
                                      (!matmul (make-tensor `(64 64)) (make-tensor `(64 64)))))
          (check-kernel schedule 1)
          (caten/codegen/expr-cache:with-expr-cache ()
            (loop for item in (gather-kernels schedule)
                  for count in `(3) do
                    (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
                      (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type))))))))
      (testing "Add(Embedding, Embedding)"
        (multiple-value-bind (schedule runtime)
            (schedule-with-vars (!add (forward (Embedding 10 10) (make-tensor `(10 10))) (forward (Embedding 10 10) (make-tensor `(10 10)))))
          (check-kernel schedule 1)
          (caten/codegen/expr-cache:with-expr-cache ()
            (loop for item in (gather-kernels schedule)
                  for count in `(3) do
                    (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
                      (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type)))))))))))
;; ~~ Testing view merge ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(deftest test-chunk-schedule
  (multiple-value-bind (schedule runtime)
      (schedule-with-vars (apply #'!matmul (multiple-value-list (!chunk (make-tensor `(2 64 64)) 2))))
    (check-kernel schedule 1)
    (caten/codegen/expr-cache:with-expr-cache ()
      (loop for item in (gather-kernels schedule)
            for count in `(4) do
              (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
                (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type)))
                (testing "Valid wmma is (val_2+(val_4[(((4096*a)+(64*b))+d)]*val_4[(((4096*(1+a))+c)+(64*d))]))"
                  (let ((wmma   (find-if #'(lambda (x)
                                             (and (eql (node-type x) :EXPR)
                                                  (getattr x :reduction :allow-undefined t)))
                                         bp))
                        (renderer 'caten/codegen/renderer:CStyle-Renderer)
                        (index-space (map 'list #'(lambda (x) (expr-const x :int64)) '(a b c d))))
                    (flet ((r (n)
                             (caten/codegen/renderer:render-expr renderer (getattr n :EXPR) :index-space index-space)))
                      (ok (equalp (r wmma) "(val_2+(val_4[(((4096*a)+(64*b))+d)]*val_4[(((4096*(1+a))+c)+(64*d))]))") (format nil "WMMA Part is rendered as ~a" (r wmma)))
                      (let ((type (caten/codegen/shape-inference:read-type-relay wmma)))
                        (ok (= (length (remove-duplicates (node-reads wmma))) 3))
                        (ok (equal `(4096 64 1 1) (buffer-stride (nth 3 (caten/codegen/shape-inference:relay-reads type))))))))))))))

(deftest test-view-merge-failing-case
  (let ((schedule (schedule-with-vars (!gelu (!matmul (make-tensor `(1 64 64)) (!t (make-tensor `(1 64 64))))))))
    (check-kernel schedule 1)))
;; ~~ Test Matmul+Activation Fusion ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(deftest matmul-gelu-fuse-1
  (testing "Matmul(X, GeLU(X))"
    (multiple-value-bind (schedule runtime) (schedule-with-vars (!matmul (make-tensor `(10 10)) (!gelu (!matmul (make-tensor `(10 10)) (make-tensor `(10 10))))))
      (check-kernel schedule 2)
      (caten/codegen/expr-cache:with-expr-cache ()
        (loop for item in (gather-kernels schedule)
              for count in `(3 3) do
                (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
                  (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type)))
                  (let* ((innermost-for
                           (position-if #'(lambda (x) (and (eql (node-type x) :FOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (innermost-endfor
                           (position-if #'(lambda (x) (and (eql (node-type x) :ENDFOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (_ (assert (and innermost-for innermost-endfor)))
                         (region (subseq bp (1+ innermost-for) innermost-endfor)))
                    (declare (ignore _))
                    ;; Activation should not be placed inside the innermost loop!
                    (let ((ng (some #'(lambda (x) (null (find (node-type x) '(:MOVE :LOAD :ADD :MUL :WMMA :AREF))))
                                    (apply #'append (map 'list #'(lambda (x) (graph-nodes (expr-graph (getattr x :EXPR)))) region)))))
                      (ng ng "The innnermost loop is consisted of only MOVE, LOAD, ADD, MUL, WMMA, AREF")))))))))

(deftest matmul-gelu-fuse-2
  (testing "Matmul(GeLU(X), X)"
    (multiple-value-bind (schedule runtime) (schedule-with-vars (!matmul (!gelu (!matmul (make-tensor `(10 10)) (make-tensor `(10 10)))) (make-tensor `(10 10)) ))
      (check-kernel schedule 2)
      (caten/codegen/expr-cache:with-expr-cache ()
        (loop for item in (gather-kernels schedule)
              for count in `(3 3) do
                (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
                  (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type)))
                  (let* ((innermost-for
                           (position-if #'(lambda (x) (and (eql (node-type x) :FOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (innermost-endfor
                           (position-if #'(lambda (x) (and (eql (node-type x) :ENDFOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (_ (assert (and innermost-for innermost-endfor)))
                         (region (subseq bp (1+ innermost-for) innermost-endfor)))
                    (declare (ignore _))
                    ;; Activation should not be placed inside the innermost loop!
                    (let ((ng (some #'(lambda (x) (null (find (node-type x) '(:MOVE :LOAD :ADD :MUL :WMMA :AREF))))
                                    (apply #'append (map 'list #'(lambda (x) (graph-nodes (expr-graph (getattr x :EXPR)))) region)))))
                      (ng ng "The innnermost loop is consisted of only MOVE, LOAD, ADD, MUL, WMMA, AREF")))))))))

(deftest matmul-sin-fuse-1
  (testing "Matmul(X, sin(X))"
    (multiple-value-bind (schedule runtime) (schedule-with-vars (!matmul (make-tensor `(10 10)) (!sin (!matmul (make-tensor `(10 10)) (make-tensor `(10 10))))))
      (check-kernel schedule 2)
      (caten/codegen/expr-cache:with-expr-cache ()
        (loop for item in (gather-kernels schedule)
              for count in `(3 3) do
                (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
                  (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type)))
                  (let* ((innermost-for
                           (position-if #'(lambda (x) (and (eql (node-type x) :FOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (innermost-endfor
                           (position-if #'(lambda (x) (and (eql (node-type x) :ENDFOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (_ (assert (and innermost-for innermost-endfor)))
                         (region (subseq bp (1+ innermost-for) innermost-endfor)))
                    (declare (ignore _))
                    ;; Activation should not be placed inside the innermost loop!
                    (let ((ng (some #'(lambda (x) (null (find (node-type x) '(:MOVE :LOAD :ADD :MUL :WMMA :AREF))))
                                    (apply #'append (map 'list #'(lambda (x) (graph-nodes (expr-graph (getattr x :EXPR)))) region)))))
                      (ng ng "The innnermost loop is consisted of only MOVE, LOAD, ADD, MUL, WMMA, AREF")))))))))

(deftest matmul-sin-fuse-2
  (testing "Matmul(sin(X), X)"
    (multiple-value-bind (schedule runtime) (schedule-with-vars (!matmul (!sin (!matmul (make-tensor `(10 10)) (make-tensor `(10 10)))) (make-tensor `(10 10)) ))
      (check-kernel schedule 2)
      (caten/codegen/expr-cache:with-expr-cache ()
        (loop for item in (gather-kernels schedule)
              for count in `(3 3) do
                (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
                  (ok (= count (count :FOR bp :key #'node-type)) (format nil "Expected ~a loops, got ~a" count (count :FOR bp :key #'node-type)))
                  (let* ((innermost-for
                           (position-if #'(lambda (x) (and (eql (node-type x) :FOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (innermost-endfor
                           (position-if #'(lambda (x) (and (eql (node-type x) :ENDFOR) (equalp (symbol-name (getattr x :idx)) "_gid2"))) bp))
                         (_ (assert (and innermost-for innermost-endfor)))
                         (region (subseq bp (1+ innermost-for) innermost-endfor)))
                    (declare (ignore _))
                    ;; Activation should not be placed inside the innermost loop!
                    (let ((ng (some #'(lambda (x) (null (find (node-type x) '(:MOVE :LOAD :ADD :MUL :WMMA :AREF))))
                                    (apply #'append (map 'list #'(lambda (x) (graph-nodes (expr-graph (getattr x :EXPR)))) region)))))
                      (ng ng "The innnermost loop is consisted of only MOVE, LOAD, ADD, MUL, WMMA, AREF")))))))))

(defun symbolic-fail-repro ()
  (with-no-grad
    (let* ((n (iconst 'n))
           (out (!add (call (Embedding 10 10) (make-tensor `(10 10))) (call (Embedding 10 10) (!cast (!add n (!index-components `(1 10))) :float32)))))
      (!add (!matmul out (!t out)) n))))

(deftest test-dynamic-shape-schedule-fail-repro
  (with-no-grad
    (multiple-value-bind (schedule runtime)
        (schedule-with-vars (symbolic-fail-repro))
      (check-kernel schedule 2)
      (caten/codegen/expr-cache:with-expr-cache ()
        (dolist (item (gather-kernels schedule))
          (let ((bp (caten/codegen/blueprint:print-blueprint (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule) nil)))
            ;; Here, val_8=n must be passed as a uint64_t, not a poitner!
            ;; If the dynamic shape is appeared across different kernels, without proper patching, the dynamic shape is loaded as a pointer which is unexpected.
            (ok
             (or (cl-ppcre:scan "val_37 = n;" bp))
             (format nil "Rendererd:~%~a" bp))))))))

(deftest test-assign-schedule
  (with-no-grad
    (multiple-value-bind (schedule runtime) (schedule-with-vars (!assign (make-tensor `(3 3) :from 'a) (make-tensor `(3 3) :from 'b)))
      (check-kernel schedule 1)
      (caten/codegen/expr-cache:with-expr-cache ()
        (dolist (item (gather-kernels schedule))
          (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
            ;; MoveAfterReduction rule should not applied here.
            (ok (= 1 (count :EXPR bp :key #'node-type)))))))))

(defun make-k-cache-kernel ()
  (let* ((batch-size 1) (max-context-len 128) (n-heads 4) (head-dim 4)
         (k-cache-data (linspace `(,batch-size ,max-context-len ,n-heads ,head-dim) 0 0 :id 'k_cache_data))
         (start-pos (iconst 'start_pos))
         (seq-len   (iconst 'seq_len))
         (range1 (list start-pos (!+ start-pos seq-len)))
         (range2 (list 0 (!+ start-pos seq-len)))
         (k (make-tensor `(,batch-size ,seq-len ,n-heads ,head-dim) :from 'k :id 'k_input))
         (k-cache (!assign (!view k-cache-data t range1 t t) k))
         (k-cache (!copy (!view-from-base k-cache t range2 t t))))
    k-cache))

(deftest test-k-cache-schedule
  (with-no-grad
    (multiple-value-bind (schedule runtime) (schedule-with-vars (make-k-cache-kernel))
      (check-kernel schedule 2)
      (caten/codegen/expr-cache:with-expr-cache ()
        (dolist (item (gather-kernels schedule))
          (let ((bp (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)))
            ;; Assume the first one is a reduce, the second one is contiguous.
            (if (find-if #'(lambda (x) (getattr x :reduction :allow-undefined t)) (getattr item :items))
                (let ((expr (find :EXPR bp :key #'node-type)))
                  (ok (= 1 (count :EXPR bp :key #'node-type))
                      (format nil "Expected 1 reduction, got ~a" (count :EXPR bp :key #'node-type)))
                  (ok (equal (node-writes expr) `(K_CACHE_DATA)))
                  (ok (equal (node-reads expr) `(K_CACHE_DATA K_INPUT))))
                (let ((expr (find :EXPR bp :key #'node-type)))
                  (ok (= 1 (count :EXPR bp :key #'node-type))
                      (format nil "Expected 1 contiguous, got ~a" (count :EXPR bp :key #'node-type)))
                  (let* ((read-type (car (caten/codegen/shape-inference:relay-read-iters (caten/codegen/shape-inference:read-type-relay expr)))))
                    (ok (every #'(lambda (x) (or (null x) (eql 0 (car x)))) (caten/codegen/shape-inference:iteration-space-views read-type))
                        "The second kernel should not create a offset for rhs."))))))))))
(deftest test-loop-collapse
  (macrolet ((def (shape axis expected-loops)
               `(multiple-value-bind (schedule runtime) (schedule-with-vars (!sum (make-tensor ',shape) :axis ,axis))
                  (assert (not (= 0 (ctx:getenv :OPTIMIZE))))
                  (check-kernel schedule 1)
                  (caten/codegen/expr-cache:with-expr-cache ()
                    (loop for item in (gather-kernels schedule) do
                      (let ((bounds (loop for node in (caten/codegen/blueprint:lower-schedule-item item (runtime-graph runtime) schedule)
                                          if (eql (node-type node) :FOR)
                                            collect (caten/codegen/scop::expr-detach-loop-bound (getattr node :below)))))
                        (ok (= (length bounds) ,(length expected-loops)) (format nil "Collapsed to ~a loops" (length bounds)))
                        (ok (every #'caten/codegen/expr:expr-scalar-equivalent-p bounds (map 'list #'(lambda (x) (caten/codegen/expr:expr-const x :int64)) ',expected-loops))
                            (format nil "Scheduled loops: ~a, Expected loops: ~a" bounds ',expected-loops))))))))
    (def (3 3 3) t (27))
    (def (3 3 3) 0 (9 3))
    (def (3 3 3) 1 (3 3 3))
    (def (3 3 3) 2 (9 3))))
;;TODO:  ConvND batch_size=1
;; ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
;;
;; [Group1]
;;    |
;; [Group2]
;;    |
(defun schedule-from-graph (graph)
  (ctx:with-contextvar (:BACKEND "LISP")
    (let ((runtime (make-runtime graph :fw-outputs (graph-outputs graph))))
      (caten/codegen/shape-inference:run-type-infer runtime)
      (caten/codegen/rewriting-rules:apply-rewriting-rules runtime)
      (values (graph-schedule (runtime-graph runtime)) runtime))))
;; The most primitive way to write the fusion test
(deftest swizzle-permute-group-test ;; r1 = r2 in group-merge-p
  (let ((g (with-context
             (x  (%make-tensor `(10 10)))
             (x  (%view x `(10 10) `(0 0) `(10 10) `(1 1) `(nil nil) `(10 1))) ;; this view should be overwritten
             (y  (%make-tensor `(10 10)))
             (x  (%sin x)) ;; expect: x = sin(x[x+10*y])
             (x1 (%view x `(10 10) `(0 0) `(10 10) `(1 1) `(nil nil) `(1 10) :permute `(1 0))) ;; %sin should use this view
             (z  (%add x1 y :id 'out)))))
    (setf (graph-outputs g) (list 'out))
    (optimize-aasm g)
    ;;(->dot g)
    (multiple-value-bind (schedule runtime) (schedule-from-graph g)
      (caten/codegen/expr-cache:with-expr-cache ()
        (check-kernel schedule 1)
        (let* ((kernel (car (gather-kernels schedule)))
               (bp (caten/codegen/blueprint:lower-schedule-item kernel (runtime-graph runtime) schedule)))
          (assert (= 1 (count :EXPR bp :key #'node-type)))
          ;; (caten/codegen/blueprint:print-blueprint bp t)
          (dolist (b bp)
            (when (eql (node-type b) :EXPR)
              (let ((val_1_type (second (caten/codegen/shape-inference:relay-reads (caten/codegen/shape-inference:read-type-relay b)))))
                (ok (equal `(1 10) (buffer-stride val_1_type)))))))))))
