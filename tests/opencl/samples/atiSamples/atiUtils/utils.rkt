#lang racket
(require opencl/c
         ffi/cvector
         ffi/unsafe/cvector
         ffi/unsafe)

(provide cvector->vector)
(provide init-cl)
(provide init-cl-cps)
(provide init-cl-build)
(provide time-real)
(provide print-array)
(provide print-array:_cl_float)
(provide fill-random:_cl_uint)
(provide fill-random:_cl_float)
(provide fill-random:_cl_uchar)
(provide optimum-threads)
(provide compare)
(provide convert-argb-to-rgba)
(provide convert-rgba-to-argb)

(define (convert-argb-to-rgba pixels)
  (for ([i (in-range (/ (bytes-length pixels) 4))])
    (define index (* i 4))
    (define c (bytes-ref pixels index))
    (for ([j (in-range index (+ index 3))])
      (bytes-set! pixels j (bytes-ref pixels (add1 j))))
    (bytes-set! pixels (+ index 3) c)))

(define (convert-rgba-to-argb pixels)
  (for ([i (in-range (/ (bytes-length pixels) 4))])
    (define index (* i 4))
    (define c (bytes-ref pixels (+ index 3)))
    (for ([j (in-range (+ index 3) index -1)])
      (bytes-set! pixels j (bytes-ref pixels (sub1 j))))
    (bytes-set! pixels index c)))

(define (compare refData data length [epsilon 0.001])
  (define error 0.0)
  (define ref 0.0)
  (for ([i (in-range length)])
    (define refi (ptr-ref refData _cl_float i))
    (define datai (ptr-ref data _cl_float i))
    (define diff (- refi datai))
    (set! error (+ error (* diff diff)))
    (set! ref (* refi datai)))
  (define normRef (sqrt ref))
  (if (< ref 1e-7)
      #f
      (begin
        (let ([normError (sqrt error)])
          (set! error (/ normError normRef))
          (< error epsilon)))))

(define (optimum-threads kernel device desired)
  (define kernelWorkGroupSize (clGetKernelWorkGroupInfo:generic kernel device 'CL_KERNEL_WORK_GROUP_SIZE))
  (if (< kernelWorkGroupSize desired) kernelWorkGroupSize desired))

(define (fill-random:_cl_uint input length [max 255])
  (for ([i (in-range length)])
    (ptr-set! input _cl_uint i (random (add1 max)))))

(define (fill-random:_cl_float input length [max 10])
  (for ([i (in-range length)])
    (ptr-set! input _cl_float i (* max (random)))))

(define (fill-random:_cl_uchar input length [max 255] [seed 123])
  (random-seed seed)
  (for ([i (in-range length)])
    (ptr-set! input _cl_uchar i (random (add1 max)))))

(define (print-array arrayName arrayData length [howMuch 256])
  (define numElementsToPrint (if (< howMuch length) howMuch length))
  (printf "~n~a:~n" arrayName)
  (for ([i (in-range numElementsToPrint)])
    (printf "~a " (ptr-ref arrayData _cl_uint i)))
  (display (if (< numElementsToPrint length) "...\n" "\n")))

(define (print-array:_cl_float arrayName arrayData length [howMuch 256])
  (define numElementsToPrint (if (< howMuch length) howMuch length))
  (printf "~n~a:~n" arrayName)
  (for ([i (in-range numElementsToPrint)])
    (printf "~a " (ptr-ref arrayData _cl_float i)))
  (display (if (< numElementsToPrint length) "...\n" "\n")))

(define (time-real proc)
  (define-values (a b t c) (time-apply proc '()))
  (/ t 1000))

(define (init-cl source #:deviceType [deviceType 'CL_DEVICE_TYPE_GPU] #:queueProperties [queueProperties '()] #:buildOptions [buildOptions (make-bytes 0)])
  (define platform (cvector-ref (clGetPlatformIDs:vector) 0))
  (define devices (clGetDeviceIDs:vector platform deviceType))
  (define context (clCreateContext #f (cvector->vector devices)))
  (define commandQueue (clCreateCommandQueue context (cvector-ref devices 0) queueProperties))
  (define program (clCreateProgramWithSource context (vector (file->bytes source))))
  (clBuildProgram program (make-vector 0) buildOptions)
  (values devices context commandQueue program))

(define (init-cl-build source #:deviceType [deviceType 'CL_DEVICE_TYPE_GPU] #:queueProperties [queueProperties '()] #:buildOptions [buildOptions (make-bytes 0)])
  (define platform (cvector-ref (clGetPlatformIDs:vector) 0))
  (define devices (clGetDeviceIDs:vector platform deviceType))
  (define device (cvector-ref devices 0))
  (define context (clCreateContext #f (cvector->vector devices)))
  (define commandQueue (clCreateCommandQueue context device queueProperties))
  (define program (clCreateProgramWithSource context (vector (file->bytes source))))
  (with-handlers ((exn:fail? (lambda (exn)
                               (define status (clGetProgramBuildInfo:generic program device 'CL_PROGRAM_BUILD_STATUS))
                               (display status))))
    (clBuildProgram program (make-vector 0) buildOptions))
  (values devices context commandQueue program))

(define (init-cl-cps source #:deviceType [deviceType 'CL_DEVICE_TYPE_GPU] #:queueProperties [queueProperties '()] #:buildOptions [buildOptions (make-bytes 0)])
  (define platform (cvector-ref (clGetPlatformIDs:vector) 0))
  (define props (vector CL_CONTEXT_PLATFORM platform 0))
  (define context (clCreateContextFromType props deviceType))
  (define devices (clGetContextInfo:generic context 'CL_CONTEXT_DEVICES))
  (define commandQueue (clCreateCommandQueue context (cvector-ref devices 0) queueProperties))
  (define program (clCreateProgramWithSource context (vector (file->bytes source))))
  (clBuildProgram program (make-vector 0) buildOptions)
  (values devices context commandQueue program))

(define (cvector->vector cv)
  (build-vector (cvector-length cv)
                (curry cvector-ref cv)))