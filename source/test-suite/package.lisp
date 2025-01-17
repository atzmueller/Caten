(in-package :cl-user)

(defpackage :caten/test-suite
  (:use :cl :rove :trivia
   :caten :caten/nn :caten/air :caten/aasm
   :caten/runtime :caten/common.dtype :alexandria
   :caten/codegen :caten/llm :py4cl
   :caten/codegen/scheduler :caten/codegen/expr :caten/codegen/jit))

(in-package :caten/test-suite)

;; running the tests requires something like "pip install torch", "pip install gguf"
;; and of course a runnable python ...

(python-exec "import torch
import struct
import gguf
import torch.nn.functional as f
import numpy as np")

(import-module "numpy" :as "np" :reload t)
(import-module "struct" :reload t)
(import-module "gguf" :as "gguf" :reload t)
(import-module "torch.nn.functional" :as "f" :reload t)
(import-function "torch.from_numpy")
(import-function "torch.matmul")
(import-function "torch.transpose")
(import-function "list" :as "py.list")
(import-function "slice")
