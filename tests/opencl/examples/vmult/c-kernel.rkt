#lang superc
(require racket/unsafe/ops)

(define kernel (get-ffi-obj-from-this 'kernel (_fun _float -> _float)))

(define HOW-MANY (read))
(define the-vector (make-vector HOW-MANY 0))

(for ([i (in-range HOW-MANY)])
  (unsafe-vector-set! the-vector i (read)))

(time
 (for ([i (in-range HOW-MANY)])
   (unsafe-vector-set! 
    the-vector i
    (kernel (unsafe-vector-ref the-vector i)))))

@c{
 float kernel (float e) {
  return e*e;
 }
}
