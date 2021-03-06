;;; color-tools.el --- color tools for emacs -*- coding: utf-8; lexical-binding: t -*-

;; Copyright (c) 2020 neeasade
;;
;; Version: 0.1
;; Author: neeasade
;; Keywords: color, theming
;; URL: https://github.com/neeasade/color-tools.el
;; Package-Requires: (dash hsluv)

;;; Commentary:
;; neeasade's color tools for emacs.
;; primarily oriented towards a consistent interface into color spaces.

;;; other:
;; note: the rgb conversion functions in HSLuv lib handle linear transformation of rgb colors

(require 'color)
(require 'hsluv)
(require 'dash)

(defalias 'first 'car)
(defalias 'second 'cadr)
(defalias 'third 'caddr)

(defcustom ct/always-shorten t
  "Whether results of color functions should ensure format #HHHHHH rather than #HHHHHHHHHHHH."
  :type 'boolean
  :group 'color-tools)

(defun ct/shorten (color)
  "Optionally transform COLOR #HHHHHHHHHHHH to #HHHHHH"
  (if (= (length color) 7)
    color
    (-as-> color C
      (color-name-to-rgb C)
      `(color-rgb-to-hex ,@C 2)
      (eval C))))

(defun ct/maybe-shorten (color)
  "Internal function -- see variable ct/always-shorten"
  (if ct/always-shorten
    (ct/shorten color)
    color))

(defun ct/name-to-lab (name &optional white-point)
  "Transform NAME into LAB colorspace with some lighting assumption."
  (-as-> name <>
    (color-name-to-rgb <>)
    (apply 'color-srgb-to-xyz <>)
    (append <> (list (or white-point color-d65-xyz)))
    (apply 'color-xyz-to-lab <>)))

(defun ct/lab-to-name (lab &optional white-point)
  "Convert LAB color to name"
  (->> (append lab (list (or white-point color-d65-xyz)))
    (apply 'color-lab-to-xyz)
    (apply 'color-xyz-to-srgb)
    ;; when pulling it out we might die
    (-map 'color-clamp)
    (apply 'color-rgb-to-hex)
    (ct/maybe-shorten)))

(defun ct/is-light-p (name &optional scale )
  (> (first (ct/name-to-lab name)) (or scale 65)))

(defun ct/greaten (percent color)
  "Make a light color lighter, a dark color darker"
  (ct/shorten
    (if (ct/is-light-p color)
      (color-lighten-name color percent)
      (color-darken-name color percent))))

(defun ct/lessen (percent color)
  "Make a light color darker, a dark color lighter"
  (ct/shorten
    (if (ct/is-light-p color)
      (color-darken-name color percent)
      (color-lighten-name color percent))))

(defun ct/iterations (start op condition)
  "Do OP on START color until CONDITION is met or op has no effect - return all intermediate steps."
  (let ((colors (list start))
         (iterations 0))
    (while (and (not (funcall condition (-last-item colors)))
             (not (string= (funcall op (-last-item colors)) (-last-item colors)))
             (< iterations 10000))
      (setq iterations (+ iterations 1))
      (setq colors (-snoc colors (funcall op (-last-item colors)))))
    colors))

(defun ct/iterate (start op condition)
  "Do OP on START color until CONDITION is met or op has no effect."
  (-last-item (ct/iterations start op condition)))

(defun ct/tint-ratio (c against ratio)
  (ct/iterate c
    (if (ct/is-light-p against)
      'ct/lab-darken
      'ct/lab-lighten)
    (lambda (step) (> (ct/contrast-ratio step against) ratio))))

(defun ct/luminance-srgb (color)
  ;; cf https://www.w3.org/TR/2008/REC-WCAG20-20081211/#relativeluminancedef
  (let ((rgb (-map
               (lambda (part)
                 (if (<= part 0.03928)
                   (/ part 12.92)
                   (expt (/ (+ 0.055 part) 1.055) 2.4)))
               (color-name-to-rgb color))))
    (+
      (* (nth 0 rgb) 0.2126)
      (* (nth 1 rgb) 0.7152)
      (* (nth 2 rgb) 0.0722))))

(defun ct/contrast-ratio (c1 c2)
  ;; cf https://peteroupc.github.io/colorgen.html#Contrast_Between_Two_Colors
  (let ((rl1 (ct/luminance-srgb c1))
         (rl2 (ct/luminance-srgb c2)))
    (/ (+ 0.05 (max rl1 rl2))
      (+ 0.05 (min rl1 rl2)))))

(defun ct/lab-change-whitepoint (name w1 w2)
  "convert a color wrt white points W1 and W2 through the lab colorspace"
  (ct/lab-to-name (ct/name-to-lab name w1) w2))

(defun ct/name-distance (c1 c2)
  ;; note: there are 3 additional optional params to cie-de2000: compensation for
  ;; {lightness,chroma,hue} (all 0.0-1.0)
  ;; https://en.wikipedia.org/wiki/Color_difference#CIEDE2000
  (apply 'color-cie-de2000 (-map 'ct/name-to-lab (list c1 c2))))

;; transformers
(defun ct/transform-lab (color transform)
  "Work with a color in the LAB space. Ranges for LAB are 0-100, -100 -> 100, -100 -> 100"
  (->> color
    (ct/name-to-lab)
    (apply transform)
    (ct/lab-to-name)))

(defun ct/transform-lch (c transform)
  "Perform a transformation in the LAB LCH space. LCH values are {0-100, 0-100, 0-360}"
  ;; color-lab-to-lch returns a form with H in radians.
  ;; we do some hamfisted handling here for a consistent expectation.
  (ct/transform-lab c
    (lambda (L A B)
      (apply 'color-lch-to-lab
        (let ((result (apply transform
                        (append
                          (-take 2 (color-lab-to-lch L A B))
                          (list (radians-to-degrees (third (color-lab-to-lch L A B))))))))
          (append
            ;; (-map (lambda (p) (* 100.0 p)) (-take 2 result))
            (-take 2 result)
            (list (degrees-to-radians (mod (third result) 360.0)))))))))

(defun ct/transform-hsl (c transform)
  "Tweak C in the HSL colorspace. Transform gets HSL in values {0-360,0-100,0-100}"
  (->> (color-name-to-rgb c)
    (apply 'color-rgb-to-hsl)
    ((lambda (hsl)
       (apply transform
         (list
           (* 360.0 (first hsl))
           (* 100.0 (second hsl))
           (* 100.0 (third hsl))))))
    ;; from transformed to what color.el expects
    ((lambda (hsl)
       (list
         (/ (mod (first hsl) 360) 360.0)
         (/ (second hsl) 100.0)
         (/ (third hsl) 100.0))))
    (-map 'color-clamp)
    (apply 'color-hsl-to-rgb)
    (apply 'color-rgb-to-hex)
    (ct/maybe-shorten)))

(defun ct/transform-hsluv (c transform)
  "Tweak a color in the HSLuv space. S,L range is {0-100}"
  (ct/maybe-shorten
    (apply 'color-rgb-to-hex
      (-map 'color-clamp
        (hsluv-hsluv-to-rgb
          (let ((result (apply transform (-> c ct/shorten hsluv-hex-to-hsluv))))
            (list
              (mod (first result) 360.0)
              (second result)
              (third result))))))))

;; individual property tweaks:
(defmacro ct/transform-prop (transform index)
  `(,transform c
     (lambda (&rest args)
       (-replace-at ,index
         (if (functionp func)
           (funcall func (nth ,index args))
           func)
         args))))

(defun ct/transform-hsl-h (c func) (ct/transform-prop ct/transform-hsl 0))
(defun ct/transform-hsl-s (c func) (ct/transform-prop ct/transform-hsl 1))
(defun ct/transform-hsl-l (c func) (ct/transform-prop ct/transform-hsl 2))

(defun ct/transform-hsluv-h (c func) (ct/transform-prop ct/transform-hsluv 0))
(defun ct/transform-hsluv-s (c func) (ct/transform-prop ct/transform-hsluv 1))
(defun ct/transform-hsluv-l (c func) (ct/transform-prop ct/transform-hsluv 2))

(defun ct/transform-lch-l (c func) (ct/transform-prop ct/transform-lch 0))
(defun ct/transform-lch-c (c func) (ct/transform-prop ct/transform-lch 1))
(defun ct/transform-lch-h (c func) (ct/transform-prop ct/transform-lch 2))

(defun ct/transform-lab-l (c func) (ct/transform-prop ct/transform-lab 0))
(defun ct/transform-lab-a (c func) (ct/transform-prop ct/transform-lab 1))
(defun ct/transform-lab-b (c func) (ct/transform-prop ct/transform-lab 2))

(defun ct/getter (c transform getter)
  (let ((return))
    (apply transform
      (list c
        (lambda (&rest _)
          (setq return (funcall getter _))
          _)))
    return))

(defun ct/get-lab (c) (ct/getter c 'ct/transform-lab 'identity))
(defun ct/get-lab-l (c) (ct/getter c 'ct/transform-lab 'first))
(defun ct/get-lab-a (c) (ct/getter c 'ct/transform-lab 'second))
(defun ct/get-lab-b (c) (ct/getter c 'ct/transform-lab 'third))

(defun ct/get-hsl (c) (ct/getter c 'ct/transform-hsl 'identity))
(defun ct/get-hsl-h (c) (ct/getter c 'ct/transform-hsl 'first))
(defun ct/get-hsl-s (c) (ct/getter c 'ct/transform-hsl 'second))
(defun ct/get-hsl-l (c) (ct/getter c 'ct/transform-hsl 'third))

(defun ct/get-hsluv (c) (ct/getter c 'ct/transform-hsluv 'identity))
(defun ct/get-hsluv-h (c) (ct/getter c 'ct/transform-hsluv 'first))
(defun ct/get-hsluv-s (c) (ct/getter c 'ct/transform-hsluv 'second))
(defun ct/get-hsluv-l (c) (ct/getter c 'ct/transform-hsluv 'third))

(defun ct/get-lch (c) (ct/getter c 'ct/transform-lch 'identity))
(defun ct/get-lch-l (c) (ct/getter c 'ct/transform-lch 'first))
(defun ct/get-lch-c (c) (ct/getter c 'ct/transform-lch 'second))
(defun ct/get-lch-h (c) (ct/getter c 'ct/transform-lch 'third))

;; other color functions:
(defun ct/lab-lighten (c &optional value)
  (ct/transform-lab-l c (-partial '+ (or value 0.5))))

(defun ct/lab-darken (c &optional value)
  (ct/transform-lab-l c (-rpartial '- (or value 0.5))))

(defun ct/pastel (c &optional Smod Vmod)
  "Make a color C more 'pastel' in the hsl space -- optionally change the rate of change with SMOD and VMOD."
  ;; cf https://en.wikipedia.org/wiki/Pastel_(color)
  ;; pastel colors belong to a pale family of colors, which, when described in the HSV color space,
  ;; have high value and low saturation.
  (ct/transform-hsl c
    (lambda (H S L)
      (list
        H
        (* S (or Smod 0.9))
        (* L (or Vmod 1.1))))))

(defun ct/gradient (step start end &optional with-ends)
  "Create a gradient length STEP from START to END, optionally including START and END"
  (if with-ends
    `(,start
       ,@(-map
           (lambda (c) (eval `(color-rgb-to-hex ,@c 2)))
           (color-gradient
             (color-name-to-rgb start)
             (color-name-to-rgb end)
             (- step 2)))
       ,end)
    (-map
      (lambda (c) (eval `(color-rgb-to-hex ,@c 2)))
      (color-gradient
        (color-name-to-rgb start)
        (color-name-to-rgb end)
        step))))

;; make colors within our normalized transform functions:
(defun ct/make-color-meta (transform properties)
  (apply transform
    (list "#cccccc"                     ; throwaway
      (lambda (&rest _) properties))))

(defun ct/make-hsl (H S L) (ct/make-color-meta 'ct/transform-hsl (list H S L)))
(defun ct/make-hsluv (H S L) (ct/make-color-meta 'ct/transform-hsluv (list H S L)))
(defun ct/make-lab (L A B) (ct/make-color-meta 'ct/transform-lab (list L A B)))
(defun ct/make-lch (L C H) (ct/make-color-meta 'ct/transform-lch (list L C H)))

(defun ct/rotation-hsluv (c interval)
  "perform a hue rotation in the HSLuv color space"
  (-map (lambda (offset) (ct/transform-hsluv-h c (-partial '+ offset)))
    (number-sequence 0 359 interval)))

(defun ct/rotation-hsl (c interval)
  "perform a hue rotation in the HSLuv color space"
  (-map (lambda (offset) (ct/transform-hsl-h c (-partial '+ offset)))
	  (number-sequence 0 359 interval)))

(defun ct/rotation-lch (c interval)
  "perform a hue rotation in the HSLuv color space"
  (-map (lambda (offset) (ct/transform-lch-h c (-partial '+ offset)))
	  (number-sequence 0 359 interval)))

(provide 'color-tools)
