;;;; Monadic parsing package for Common Lisp
;;;;
;;;; Copyright (c) Jeffrey Massung
;;;;
;;;; This file is provided to you under the Apache License,
;;;; Version 2.0 (the "License"); you may not use this file
;;;; except in compliance with the License.  You may obtain
;;;; a copy of the License at
;;;;
;;;;    http://www.apache.org/licenses/LICENSE-2.0
;;;;
;;;; Unless required by applicable law or agreed to in writing,
;;;; software distributed under the License is distributed on an
;;;; "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
;;;; KIND, either express or implied.  See the License for the
;;;; specific language governing permissions and limitations
;;;; under the License.
;;;;

(defpackage :parse
  (:use :cl)
  (:export
   #:parse

   ;; declare a parse combinator
   #:define-parser

   ;; monadic bind functions
   #:>>=
   #:>>

   ;; combinator macros
   #:.let
   #:.let*
   #:.do
   #:.or

   ;; monadic functions
   #:.ret
   #:.fail
   #:.get
   #:.put
   #:.modify
   #:.push
   #:.pop

   ;; parse combinators
   #:.any
   #:.eof
   #:.is
   #:.either
   #:.opt
   #:.ignore
   #:.maybe
   #:.many
   #:.many1
   #:.many-until
   #:.sep-by
   #:.sep-by1
   #:.skip-many
   #:.skip-many1
   #:.between))

(in-package :parse)

;;; ----------------------------------------------------

(defstruct parse-state read-token tokens token-last data)

;;; ----------------------------------------------------

(defun parse-state-next-token (st)
  "Returns the next token in the token list as a cons pair."
  (cadr (parse-state-tokens st)))

;;; ----------------------------------------------------

(defun parse-state-token-class (st)
  "Returns the class of the current token."
  (car (parse-state-next-token st)))

;;; ----------------------------------------------------

(defun parse-state-token-value (st)
  "Returns the value of the current token."
  (cdr (parse-state-next-token st)))

;;; ----------------------------------------------------

(defun parse (p next-token &key initial-state (errorp t) error-value)
  "Create a parse-state and pass it through a parse combinator."
  (let* ((token-cache (list nil))

         ;; create the initial parse state
         (st (make-parse-state :tokens token-cache
                               :token-last token-cache
                               :data initial-state)))

    ;; create a function that will read into the shared token list
    (setf (parse-state-read-token st)
          #'(lambda ()
              (multiple-value-bind (class value)
                  (funcall next-token)
                (car (setf (parse-state-token-last st)
                           (cdr (rplacd (parse-state-token-last st)
                                        (list (cons class value)))))))))

    ;; read the first token as the current token
    (funcall (parse-state-read-token st))

    ;; parse the token stream
    (handler-case
        (multiple-value-bind (x okp)
            (funcall p st)
          (if okp
              (values x t)
            (error "Parse failure")))
      (condition (c)
        (if errorp
            (error c)
          (values error-value nil))))))

;;; ----------------------------------------------------

(defun satisfy (st pred)
  "Read the next token if necesary, test class, return value."
  (destructuring-bind (class . value)
      (let ((token (parse-state-next-token st)))
        (if token
            token
          (funcall (parse-state-read-token st))))
    (when (funcall pred class)
      (let ((nst (copy-parse-state st)))
        (multiple-value-prog1
            (values value nst)
          (pop (parse-state-tokens nst)))))))

;;; ----------------------------------------------------

(defmacro define-parser (name &body ps)
  "Create a parse combinator."
  (let ((st (gensym)))
    `(defun ,name (,st)

       ;; add a documentation string to the parser if provided
       ,(when (stringp (first ps)) (pop ps))

       ;; parse the combinators, return the final result
       (funcall (.do ,@ps) ,st))))

;;; ----------------------------------------------------

(defun >>= (p f)
  "Monadic bind combinator."
  #'(lambda (st)
      (multiple-value-bind (x nst)
          (funcall p st)
        (when nst
          (funcall (funcall f x) nst)))))

;;; ----------------------------------------------------

(defun >> (p m)
  "Monadic bind, ignore intermediate result."
  #'(lambda (st)
      (let ((nst (nth-value 1 (funcall p st))))
        (when nst
          (funcall m nst)))))

;;; ----------------------------------------------------

(defmacro .let ((var p) &body body)
  "Macro for >>= to make it more readable."
  `(>>= ,p #'(lambda (,var) (declare (ignorable ,var)) ,@body)))

;;; ----------------------------------------------------

(defmacro .let* ((binding &rest bindings) &body body)
  "Macro for making multiple .let bindings more readable."
  (if (null bindings)
      `(.let ,binding ,@body)
    `(.let ,binding
       (.let* ,bindings ,@body))))

;;; ----------------------------------------------------

(defmacro .do (p &rest ps)
  "Chained together >> combinators."
  (labels ((chain (p ps)
             (if (null ps)
                 p
               `(>> ,p ,(chain (first ps) (rest ps))))))
    (chain p ps)))

;;; ----------------------------------------------------

(defmacro .or (p &rest ps)
  "Chained together or combinators."
  (labels ((try (p ps)
             (if (null ps)
                 p
               `(.either ,p ,(try (first ps) (rest ps))))))
    (try p ps)))

;;; ----------------------------------------------------

(defun .ret (x)
  "Convert X into a monadic value."
  #'(lambda (st) (values x st)))

;;; ----------------------------------------------------

(defun .fail (datum &rest arguments)
  "Ensures that the parse combinator fails."
  #'(lambda (st)
      (declare (ignore st))
      (apply #'error datum arguments)))

;;; ----------------------------------------------------

(defun .get ()
  "Always succeeds, returns the current parse state data."
  #'(lambda (st)
      (values (parse-state-data st) st)))

;;; ----------------------------------------------------

(defun .put (x)
  "Always succeeds, puts data into the parse state."
  #'(lambda (st)
      (let ((nst (copy-parse-state st)))
        (values (setf (parse-state-data nst) x) nst))))

;;; ----------------------------------------------------

(defun .modify (f)
  "Always succeeds, applys f with the parse state data."
  (.let (x (.get))
    (.put (funcall f x))))

;;; ----------------------------------------------------

(defun .push (x)
  "Always succeeds, assumes data is a list and pushes x onto it."
  (.let (xs (.get))
    (.put (cons x xs))))

;;; ----------------------------------------------------

(defun .pop ()
  "Always succeeds, assumes data is a list an pops it."
  (.let (xs (.get))
    (.do (.put (cdr xs))
         (.ret (car xs)))))

;;; ----------------------------------------------------

(defun .any ()
  "Succeeds if not at the end of the token stream."
  #'(lambda (st) (satisfy st #'identity)))

;;; ----------------------------------------------------

(defun .eof ()
  "Succeeds if at the end of the token stream."
  #'(lambda (st) (satisfy st #'null)))

;;; ----------------------------------------------------

(defun .is (class &key (test #'eql))
  "Checks if the current token is of a given class."
  #'(lambda (st) (satisfy st #'(lambda (c) (funcall test c class)))))

;;; ----------------------------------------------------

(defun .either (p1 p2)
  "Attempt to parse p1, if that fails, try p2."
  #'(lambda (st)
      (multiple-value-bind (x nst)
          (funcall p1 st)
        (if nst
            (values x nst)
          (funcall p2 st)))))

;;; ----------------------------------------------------

(defun .opt (x p)
  "Optionally match a parse combinator or return x."
  (.either p (.ret x)))

;;; ----------------------------------------------------

(defun .ignore (p)
  "Parse p, ignore the result."
  (.do p (.ret nil)))

;;; ----------------------------------------------------

(defun .maybe (p)
  "Try and parse p, ignore it if there."
  (.opt nil (.ignore p)))

;;; ----------------------------------------------------

(defun .many (p)
  "Try and parse a combinator zero or more times."
  (.opt nil (.many1 p)))

;;; ----------------------------------------------------

(defun .many1 (p)
  "Try and parse a combinator one or more times."
  (.let (x p)
    (.let (xs (.many p))
      (.ret (cons x xs)))))

;;; ----------------------------------------------------

(defun .many-until (p term)
  "Parse zero or more combinators until a terminal is reached."
  (.either (.do term (.ret nil))
           (.let (x p)
             (.let (xs (.many-until p term))
               (.ret (cons x xs))))))

;;; ----------------------------------------------------

(defun .sep-by (p sep)
  "Zero or more occurances of p separated by sep."
  (.opt nil (.sep-by1 p sep)))

;;; ----------------------------------------------------

(defun .sep-by1 (p sep)
  "One or more occurances of p separated by sep."
  (.let (x p)
    (.let (xs (.many (.do sep p)))
      (.ret (cons x xs)))))

;;; ----------------------------------------------------

(defun .skip-many (p)
  "Optionally skip a parse combinator zero or more times."
  (.opt nil (.skip-many1 p)))

;;; ----------------------------------------------------

(defun .skip-many1 (p)
  "Try and parse a combinator one or more times, ignore it."
  (.let (x p)
    (.skip-many p)))

;;; ----------------------------------------------------

(defun .between (open-guard close-guard p)
  "Capture a combinator between guards."
  (.do open-guard (.let (x p) (.do close-guard (.ret x)))))
