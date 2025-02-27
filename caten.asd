(asdf:defsystem "caten"
  :description "Programmable Deep Learning Framework"
  :author      "hikettei <ichndm@gmail.com>"
  :version     "0.2"
  :licence     "MIT"
  :depends-on
  ("caten.api" "caten.nn")
  :serial t
  :components ((:file "source/caten-user") (:file "source/documentation"))
  :in-order-to
  ((test-op (test-op "caten/test"))))

(asdf:defsystem "caten/test"
  :description "Test suites for Caten"
  :depends-on ("caten" "caten/llm" "caten.test-suite")
  :in-order-to
  ((test-op (asdf:test-op "caten.test-suite"))))

(asdf:defsystem "caten/apps"
  :description ""
  :author "hikettei <ichndm@gmail.com>"
  :depends-on (;; More Applications follow ...
               "caten.apps.gpt2")
  :components ((:file "apps/documentation")))

;; External system for Caten.
(asdf:defsystem "caten/gguf"
  :description "[gguf](https://github.com/ggerganov/ggml/blob/master/docs/gguf.md) format translator."
  :author "hikettei <ichndm@gmail.com>"
  :depends-on ("caten.api" "caten/llm" "babel" "fast-io" "trivial-download")
  :serial t
  :pathname "external/gguf"
  :components
  ((:file "package")
   (:file "helpers")
   (:file "metadata")
   (:file "tensor-info")
   (:file "gguf-file")
   (:file "dequantize")
   (:file "documentation")))

(asdf:defsystem "caten/llm"
  :description "Various Generative Language Model Implementation in Caten"
  :author "hikettei <ichndm@gmail.com>"
  :depends-on ("caten" "cl-ppcre")
  :pathname "external/llm"
  :components
  ((:file "package")
   (:file "utils")
   (:file "tokenizers")
   (:file "bpe")
   (:file "layers")
   (:file "documentation")))

(asdf:defsystem "caten/onnx"
  :description "ONNX extension for Caten"
  :author "hikettei <ichndm@gmail.com>"
  :depends-on ("caten" "cl-onnx" "alexandria")
  :pathname "external/onnx"
  :components
  ((:file "package")
   (:file "helpers")
   (:file "defop")
   (:file "onnx")
   (:file "opset")
   (:file "documentation")))

(asdf:defsystem "caten/vision"
  :description "Computer Vision Implementation in Caten"
  :author "hikettei <ichndm@gmail.com>"
  :depends-on ("caten" "opticl")
  :pathname "external/vision"
  :components
  ((:file "package")))

(asdf:defsystem "caten/benchmarks"
  :description "A set of benchmarks for Caten"
  :author "hikettei <ichndm@gmail.com>"
  :depends-on ("caten" "caten/llm" "clgplot" "clingon")
  :pathname "external/benchmarks"
  :components
  ((:file "benchmark-simplifier")
   (:file "package")))
