#lang racket
(require opencl/c
         "../atiUtils/utils.rkt"
         ffi/unsafe
         ffi/cvector
         ffi/unsafe/cvector)

(define setupTime -1)
(define totalKernelTime -1)
(define devices #f)
(define context #f)
(define commandQueue #f)
(define program #f)
(define length 256)
(define diagonal #f)
(define offDiagonal #f)
(define eigenIntervals (make-vector 2))
(define eigenIntervalBuffer (make-vector 2))
(define verificationEigenIntervals (make-vector 2))
(define kernel (make-vector 2))
(define epsilon 0.001)
(define tolerance 0.001)
(define in 0)
(define verificationIn 0)
(define numEigenIntervals #f)
(define diagonalBuffer #f)
(define numEigenValuesIntervalBuffer #f)
(define offDiagonalBuffer #f)

(define (computeGerschgorinInterval diagonal offDiagonal length)
  (define lowerLimit (- (ptr-ref diagonal _cl_float 0) (ptr-ref offDiagonal _cl_float 0)))
  (define upperLimit (+ (ptr-ref diagonal _cl_float 0) (ptr-ref offDiagonal _cl_float 0)))
  (for ([i (in-range (sub1 length))])
    (define r (+ (ptr-ref offDiagonal _cl_float (sub1 i)) (ptr-ref offDiagonal _cl_float i)))
    (define val (ptr-ref diagonal _cl_float i))
    (set! lowerLimit (if (> lowerLimit (- val r)) (- val r) lowerLimit))
    (set! upperLimit (if (< upperLimit (+ val r)) (+ val r) upperLimit)))
  (define val1 (ptr-ref diagonal _cl_float (- length 1)))
  (define val2 (ptr-ref offDiagonal _cl_float (- length 2)))
  (set! lowerLimit (if (> lowerLimit (- val1 val2)) (- val1 val2) lowerLimit))
  (set! upperLimit (if (< upperLimit (+ val1 val2)) (+ val1 val2) upperLimit))
  (values lowerLimit upperLimit))

(define (calNumEigenValuesLessThan diagonal offDiagonal length x)
  (define count 0)
  (define prev_diff (- (ptr-ref diagonal _cl_float 0) x))
  (when (< prev_diff 0) (set! count (add1 count)))
  (for ([i (in-range 1 length)])
    (define diff (- (- (ptr-ref diagonal _cl_float i) x) (/ (* (ptr-ref offDiagonal _cl_float (sub1 i)) (ptr-ref offDiagonal _cl_float (sub1 i))) prev_diff)))
    (when (< diff 0) (set! count (add1 count)))
    (set! prev_diff diff))
  count)

(define (eigenValueCPUReference diagonal offDiagonal length eigenIntervals newEigenIntervals)
  (define offset 0)
  (for ([i (in-range length)])
    (define lid (* 2 i))
    (define uid (add1 lid))
    (define eigenValuesLowerBound (calNumEigenValuesLessThan diagonal offDiagonal length (ptr-ref eigenIntervals _cl_float lid)))
    (define eigenValuesUpperBound (calNumEigenValuesLessThan diagonal offDiagonal length (ptr-ref eigenIntervals _cl_float uid)))
    (define numSubIntervals (- eigenValuesUpperBound eigenValuesLowerBound))
    (when (> numSubIntervals 1)
      (define avgSubIntervalWidth (/ (- (ptr-ref eigenIntervals _cl_float uid) (ptr-ref eigenIntervals _cl_float lid)) numSubIntervals))
      (for ([j (in-range numSubIntervals)])
        (define newLid (* 2 (+ j offset)))
        (define newUid (add1 newLid))
        (ptr-set! newEigenIntervals _cl_float newLid (+ (ptr-ref eigenIntervals _cl_float lid) (* j avgSubIntervalWidth)))
        (ptr-set! newEigenIntervals _cl_float newUid (+ (ptr-ref newEigenIntervals _cl_float newLid) avgSubIntervalWidth))))
    (when (= numSubIntervals 1)
      (define lowerBound (ptr-ref eigenIntervals _cl_float lid))
      (define upperBound (ptr-ref eigenIntervals _cl_float uid))
      (define mid (/ (+ lowerBound upperBound) 2))
      (define newLid (* 2 offset))
      (define newUid (add1 newLid))
      (cond
        [(< (- upperBound lowerBound) tolerance)
         (ptr-set! newEigenIntervals _cl_float newLid lowerBound)
         (ptr-set! newEigenIntervals _cl_float newUid upperBound)]
        [(= (calNumEigenValuesLessThan diagonal offDiagonal length mid) eigenValuesUpperBound)
         (ptr-set! newEigenIntervals _cl_float newLid lowerBound)
         (ptr-set! newEigenIntervals _cl_float newUid mid)]
        [else
         (ptr-set! newEigenIntervals _cl_float newLid mid)
         (ptr-set! newEigenIntervals _cl_float newUid upperBound)]))
    (set! offset (+ offset numSubIntervals)))
  offset)

(define (setupEigenValue)
  (define diagonalSizeBytes (* length (ctype-sizeof _cl_float)))
  (set! diagonal (malloc diagonalSizeBytes 'raw))
  (define offDiagonalSizeBytes (* (sub1 length) (ctype-sizeof _cl_float)))
  (set! offDiagonal (malloc offDiagonalSizeBytes 'raw))
  (set! numEigenIntervals (malloc diagonalSizeBytes 'raw))
  (define eigenIntervalsSizeBytes (* 2 length (ctype-sizeof _cl_float)))
  (for ([i (in-range 2)])
    (vector-set! eigenIntervals i (malloc eigenIntervalsSizeBytes 'raw))
    (vector-set! verificationEigenIntervals i (malloc eigenIntervalsSizeBytes 'raw)))
  (fill-random:_cl_float diagonal length 255)
  (fill-random:_cl_float offDiagonal (sub1 length) 255)
  (define-values (lowerLimit upperLimit) (computeGerschgorinInterval diagonal offDiagonal length))
  (ptr-set! (vector-ref eigenIntervals 0) _cl_float 0 lowerLimit)
  (ptr-set! (vector-ref eigenIntervals 0) _cl_float 1 upperLimit)
  (for ([i (in-range 2 (* 2 length))])
    (ptr-set! (vector-ref eigenIntervals 0) _cl_float i upperLimit)))

(define (setupCL)
  (set!-values (devices context commandQueue program) (init-cl "EigenValue_Kernels.cl" #:queueProperties 'CL_QUEUE_PROFILING_ENABLE))
  (set! diagonalBuffer (clCreateBuffer context '(CL_MEM_READ_ONLY CL_MEM_USE_HOST_PTR) (* length (ctype-sizeof _cl_float)) diagonal))
  (set! numEigenValuesIntervalBuffer (clCreateBuffer context '(CL_MEM_READ_WRITE CL_MEM_USE_HOST_PTR) (* length (ctype-sizeof _cl_uint)) numEigenIntervals))
  (set! offDiagonalBuffer (clCreateBuffer context '(CL_MEM_READ_ONLY CL_MEM_USE_HOST_PTR) (* (sub1 length) (ctype-sizeof _cl_float)) offDiagonal))
  (for ([i (in-range 2)])
    (vector-set! eigenIntervalBuffer i (clCreateBuffer context '(CL_MEM_READ_WRITE CL_MEM_USE_HOST_PTR) (* length 2 (ctype-sizeof _cl_uint)) (vector-ref eigenIntervals i))))
  (vector-set! kernel 0 (clCreateKernel program #"calNumEigenValueInterval"))
  (vector-set! kernel 1 (clCreateKernel program #"recalculateEigenIntervals")))

(define (isComplete eigenIntervals)
  (define result #f)
  (let/ec break
    (for ([i (in-range length)])
      (define lid (* 2 i))
      (define uid (add1 lid))
      (define val1 (ptr-ref eigenIntervals _cl_float uid))
      (define val2 (ptr-ref eigenIntervals _cl_float lid))
      (define val3 (- val1 val2))
      (when (>= val3 tolerance)
        (set! result #t)
        (break))))
  result)

(define (runCLKernels)
  (define globalThreads length)
  (define localThreads (optimum-threads (vector-ref kernel 0) (cvector-ref devices 0) length))
  (clSetKernelArg:_cl_mem (vector-ref kernel 0) 0 numEigenValuesIntervalBuffer)
  (clSetKernelArg:_cl_mem (vector-ref kernel 0) 2 diagonalBuffer)
  (clSetKernelArg:_cl_mem (vector-ref kernel 0) 3 offDiagonalBuffer)
  (clSetKernelArg:_cl_uint (vector-ref kernel 0) 4 length)
  (clSetKernelArg:_cl_mem (vector-ref kernel 1) 2 numEigenValuesIntervalBuffer)
  (clSetKernelArg:_cl_mem (vector-ref kernel 1) 3 diagonalBuffer)
  (clSetKernelArg:_cl_mem (vector-ref kernel 1) 4 offDiagonalBuffer)
  (clSetKernelArg:_cl_uint (vector-ref kernel 1) 5 length)
  (clSetKernelArg:_cl_float (vector-ref kernel 1) 6 tolerance)
  (set! in 0)
  (let loop ()
    (when (isComplete (vector-ref eigenIntervals in))
      (clSetKernelArg:_cl_mem (vector-ref kernel 0) 1 (vector-ref eigenIntervalBuffer in))
      (clSetKernelArg:_cl_mem (vector-ref kernel 1) 0 (vector-ref eigenIntervalBuffer (- 1 in)))
      (clSetKernelArg:_cl_mem (vector-ref kernel 1) 1 (vector-ref eigenIntervalBuffer in))
      (define event (clEnqueueNDRangeKernel commandQueue (vector-ref kernel 0) 1 (vector globalThreads) (vector localThreads) (make-vector 0)))
      (clWaitForEvents (vector event))
      (clReleaseEvent event)
      (set! event (clEnqueueNDRangeKernel commandQueue (vector-ref kernel 1) 1 (vector globalThreads) (vector localThreads) (make-vector 0)))
      (clWaitForEvents (vector event))
      (clReleaseEvent event)
      (set! in (- 1 in))
      (clEnqueueReadBuffer commandQueue (vector-ref eigenIntervalBuffer in) 'CL_TRUE 0 (* length 2 (ctype-sizeof _cl_float)) (vector-ref eigenIntervals in) (make-vector 0))
      (loop)))
  (clEnqueueReadBuffer commandQueue (vector-ref eigenIntervalBuffer in) 'CL_TRUE 0 (* length 2 (ctype-sizeof _cl_float)) (vector-ref eigenIntervals in) (make-vector 0)))

(define (setup)
  (setupEigenValue)
  (set! setupTime (time-real setupCL)))

(define (run)
  (set! totalKernelTime (time-real runCLKernels)))

(define (verify-results)
  (define offset 0)
  (define-values (lowerLimit upperLimit) (computeGerschgorinInterval diagonal offDiagonal length))
  (set! verificationIn 0)
  (ptr-set! (vector-ref verificationEigenIntervals verificationIn) _cl_float 0 lowerLimit)
  (ptr-set! (vector-ref verificationEigenIntervals verificationIn) _cl_float 1 upperLimit)
  (for ([i (in-range 2 (* 2 length))])
    (ptr-set! (vector-ref verificationEigenIntervals verificationIn) _cl_float i upperLimit))
  (let loop ()
    (when (isComplete (vector-ref verificationEigenIntervals verificationIn))
      (set! offset (eigenValueCPUReference diagonal offDiagonal length 
                                           (vector-ref verificationEigenIntervals verificationIn) 
                                           (vector-ref verificationEigenIntervals (- 1 verificationIn))))
      (set! verificationIn (- 1 verificationIn))
      (loop)))
  (printf "~n~a~n" (if (compare (vector-ref eigenIntervals in) (vector-ref verificationEigenIntervals verificationIn) (* 2 length) 0.5) "Passed" "Failed")))

(define (print-stats)
  (printf "~nDiagonalLength: ~a, Setup Time: ~a, Kernel Time: ~a, Total Time: ~a~n"
          length
          (real->decimal-string setupTime 3) 
          (real->decimal-string totalKernelTime 3)
          (real->decimal-string (+ setupTime totalKernelTime) 3)))

(define (cleanup)
  (for ([i (in-range 2)])
    (clReleaseKernel (vector-ref kernel i)))
  (clReleaseProgram program)
  (for ([i (in-range 2)])
    (clReleaseMemObject (vector-ref eigenIntervalBuffer i))
    (free (vector-ref eigenIntervals i))
    (free (vector-ref verificationEigenIntervals i)))
  (clReleaseMemObject diagonalBuffer)
  (clReleaseMemObject offDiagonalBuffer)
  (clReleaseMemObject numEigenValuesIntervalBuffer)
  (clReleaseCommandQueue commandQueue)
  (clReleaseContext context)
  (free diagonal)
  (free offDiagonal)
  (free numEigenIntervals))

(setup)
(run)
(verify-results)
(cleanup)
(print-stats)