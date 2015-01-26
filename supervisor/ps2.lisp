;;;; Copyright (c) 2011-2015 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(in-package :mezzano.supervisor)

;; The controller is wired up this way on the PC.
(defconstant +ps/2-data-port+ #x60)
(defconstant +ps/2-control-port+ #x64)
(defconstant +ps/2-key-irq+ 1)
(defconstant +ps/2-aux-irq+ 12)

;;; PS/2 controller commands.
(defconstant +ps/2-read-config-byte+ #x20)
(defconstant +ps/2-write-config-byte+ #x60)
(defconstant +ps/2-disable-aux-port+ #xA7)
(defconstant +ps/2-enable-aux-port+ #xA8)
(defconstant +ps/2-test-aux-port+ #xA9)
(defconstant +ps/2-test-controller+ #xAA)
(defconstant +ps/2-test-key-port+ #xAB)
(defconstant +ps/2-disable-key-port+ #xAD)
(defconstant +ps/2-enable-key-port+ #xAE)
(defconstant +ps/2-read-controller-output-port+ #xD0)
(defconstant +ps/2-write-controller-output-port+ #xD1)
(defconstant +ps/2-write-key-port+ #xD2)
(defconstant +ps/2-write-aux-port+ #xD4)

;;; PS/2 status register bits.
(defconstant +ps/2-status-output-buffer-status+ (ash 1 0))
(defconstant +ps/2-status-input-buffer-status+ (ash 1 1))
(defconstant +ps/2-status-command/data+ (ash 1 3))
(defconstant +ps/2-status-timeout-error+ (ash 1 6))
(defconstant +ps/2-status-parity-error+ (ash 1 7))

;;; PS/2 config byte bits.
(defconstant +ps/2-config-key-interrupt+ (ash 1 0))
(defconstant +ps/2-config-aux-interrupt+ (ash 1 1))
(defconstant +ps/2-config-key-clock+ (ash 1 4))
(defconstant +ps/2-config-aux-clock+ (ash 1 5))
(defconstant +ps/2-config-key-translation+ (ash 1 6))

(defvar *ps/2-key-fifo*)
(defvar *ps/2-aux-fifo*)
(defvar *ps/2-controller-lock*)

(defun ps/2-irq-handler (fifo)
  (fifo-push (system:io-port/8 +ps/2-data-port+) fifo nil))

(defun ps/2-key-irq-handler (irq)
  (declare (ignore irq))
  (ps/2-irq-handler *ps/2-key-fifo*))

(defun ps/2-aux-irq-handler (irq)
  (declare (ignore irq))
  (ps/2-irq-handler *ps/2-aux-fifo*))

(defun ps/2-input-wait (&optional (what "data"))
  "Wait for space in the input buffer."
  ;; FIXME: Wait 1ms or something instead of this.
  (dotimes (i 100000
            (mezzano.supervisor:debug-print-line "PS/2: Timeout waiting for " what "."))
    (when (zerop (logand (system:io-port/8 +ps/2-control-port+) +ps/2-status-input-buffer-status+))
      (return t))))

(defun ps/2-output-wait (&optional (what "data"))
  "Wait for data to become available in the output buffer."
  ;; FIXME: Wait 1ms or something instead of this.
  (dotimes (i 100000
            (mezzano.supervisor:debug-print-line "PS/2: Timeout waiting for " what "."))
    (when (not (zerop (logand (system:io-port/8 +ps/2-control-port+) +ps/2-status-output-buffer-status+)))
      (return t))))

(defun ps/2-port-write (byte command)
  (with-symbol-spinlock (*ps/2-controller-lock*)
    (ps/2-input-wait)
    (setf (system:io-port/8 +ps/2-control-port+) command)
    (ps/2-input-wait)
    (setf (system:io-port/8 +ps/2-data-port+) byte)))

(defun ps/2-key-write (byte)
  "Write a byte to the key port."
  (ps/2-port-write byte +ps/2-write-key-port+))

(defun ps/2-key-read (&optional (wait-p t))
  "Read a byte from the key port."
  (fifo-pop *ps/2-key-fifo* wait-p))

(defun ps/2-aux-write (byte)
  "Write a byte to the aux port."
  (ps/2-port-write byte +ps/2-write-aux-port+))

(defun ps/2-aux-read (&optional (wait-p t))
  "Read a byte from the aux port."
  (fifo-pop *ps/2-aux-fifo* wait-p))

(defun initialize-ps/2 ()
  (when (not (boundp '*ps/2-controller-lock*))
    (setf *ps/2-controller-lock* :unlocked
          *ps/2-key-fifo* (mezzano.supervisor:make-fifo 50 :element-type '(unsigned-byte 8))
          *ps/2-aux-fifo* (mezzano.supervisor:make-fifo 50 :element-type '(unsigned-byte 8))))
  ;; Enable the aux port.
  (ps/2-input-wait)
  (setf (system:io-port/8 +ps/2-control-port+) +ps/2-enable-aux-port+)
  ;; Enable interrupts for key & aux.
  (ps/2-input-wait)
  (setf (system:io-port/8 +ps/2-control-port+) +ps/2-read-config-byte+)
  (ps/2-output-wait)
  (let ((config (logior (system:io-port/8 +ps/2-data-port+)
                        +ps/2-config-key-interrupt+
                        +ps/2-config-aux-interrupt+)))
    (ps/2-input-wait)
    (setf (system:io-port/8 +ps/2-control-port+) +ps/2-write-config-byte+)
    (ps/2-input-wait)
    (setf (system:io-port/8 +ps/2-data-port+) config))
  ;; Enable mouse defaults & reporting.
  (ps/2-aux-write #xF6)
  ;; Read response.
  (ps/2-output-wait)
  (system:io-port/8 +ps/2-data-port+)
  (ps/2-aux-write #xF4)
  (ps/2-output-wait)
  (system:io-port/8 +ps/2-data-port+)
  ;; Enable both IRQs.
  (i8259-hook-irq +ps/2-key-irq+ 'ps/2-key-irq-handler)
  (i8259-hook-irq +ps/2-aux-irq+ 'ps/2-aux-irq-handler)
  (i8259-unmask-irq +ps/2-key-irq+)
  (i8259-unmask-irq +ps/2-aux-irq+)
  ;; Data may have accumulated in the FIFOs.
  (fifo-reset *ps/2-key-fifo*)
  (fifo-reset *ps/2-aux-fifo*))
