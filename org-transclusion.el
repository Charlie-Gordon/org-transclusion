;;; org-transclusion.el --- transclude text contents of linked target -*- lexical-binding: t; -*-

;; Copyright (C) 2020-21 Noboru Ota

;; Author: Noboru Ota <me@nobiot.com>
;; URL: https://github.com/nobiot/org-transclusion
;; Keywords: org-mode, transclusion, writing

;; Version: 0.1.2
;; Package-Requires: ((emacs "27.1") (org "9.4"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation, either version 3 of the License, or (at your
;; option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License along
;; with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This library is an attempt to enable transclusion with Org Mode.
;; Transclusion is the ability to include content from one file into
;; another by reference.

;; It is still VERY experimental.  As it modifies your files (notes), use
;; it with care.  The author and contributors cannot be held responsible
;; for loss of important work.

;; Org-transclusion is a buffer-local minor mode.  It is suggested to set a
;; keybinding like this to make it easy to toggle it:
;;     (define-key global-map (kbd "<f12>") #'org-transclusion-mode)

;;; Code:

;;;; Requirements
(require 'org)
(require 'org-element)
(require 'org-id)
(require 'text-clone)
(declare-function org-at-keyword-p 'org)
(declare-function text-property-search-forward 'text-property-search)
(declare-function text-property-search-backward 'text-property-search)
(declare-function prop-match-value 'text-property-search)

;;;; Customization

(defgroup org-transclusion nil
  "Insert text contents by way of link references."
  :group 'org
  :prefix "org-transclusion-"
  :link '(url-link :tag "Github" "https://github.com/nobiot/org-transclusion"))

(defcustom org-transclusion-add-all-on-activate t
  "Define whether to add all the transclusions on activation.
When non-nil, automatically add all on `org-transclusion-activate'."
  :type 'boolean
  :group 'org-transclusion)

(defcustom org-transclusion-exclude-elements (list 'property-drawer)
  "Define the Org elements that are excluded from transcluded copies.
It is a list of elements to be filtered out.
Refer to variable `org-element-all-elements' for names of elements accepted."
  :type '(repeat symbol)
  :group 'org-transclusion)

(defcustom org-transclusion-include-first-section nil
  "Define whether or not transclusion for Org files includes \"first section\".
If t, the section before the first headline is
transcluded. Default is nil."
  :type 'boolean
  :group 'org-transclusion)

(defcustom org-transclusion-add-at-point-functions (list "others-default")
  "Define list of `link types' org-tranclusion supports.
In addtion to a element in the list, there must be two
corresponding functions with specific names

The functions must conform to take specific arguments, and to returnbvalues.

org-transclusion-match-<org-id>
org-transclusion-add-<org-id>

See the functions delivered within org-tranclusion for the API signatures."
  :type '(repeat string)
  :group 'org-transclusion)

(defcustom org-transclusion-regexp-search-function 'org-transclusion-regexp-search-default
  "Function to call when file link has /REGEXP/ search option
Note: This function should take REGEXP as it argument and match only once.
The default `org-transclusion-regexp-search-default' matches the single last occurance of REGEXP."
  :type 'function
  :group 'org-transclusion)

(defcustom org-transclusion-line-search-style 'paragraph
  "Key that determines the function in `org-transclusion-line-search-handler'
 See the documentation of `org-transclusion-line-search-handler' for more information"
  :options '(paragraph one-line)
  :group 'org-transclusion)

;;;; Faces

(defface org-transclusion-source-fringe
  '((((class color) (min-colors 88) (background light)))
    (((class color) (min-colors 88) (background dark)))
    (t ))
  "Face for source region's fringe being transcluded in another
buffer."
  :group 'org-transclusion)

(defface org-transclusion-source
  '((((class color) (min-colors 88) (background light))
     :background "#ebf6fa" :extend t)
    (((class color) (min-colors 88) (background dark))
     :background "#041529" :extend t)
    (t
     :foreground "darkgray"))
  "Face for source region being transcluded in another buffer."
  :group 'org-transclusion)

(defface org-transclusion-source-edit
  '((((class color) (min-colors 88) (background light))
     :background "#fff3da" :extend t)
    (((class color) (min-colors 88) (background dark))
     :background "#221000" :extend t)
    (t
     :background "chocolate4" :extend t))
  "Face for element in the source being edited by another
buffer."
  :group 'org-transclusion)

(defface org-transclusion-fringe
  '((((class color) (min-colors 88) (background light)))
    (((class color) (min-colors 88) (background dark)))
    (t ))
  "Face for transcluded region's fringe in the transcluding
buffer."
  :group 'org-transclusion)

(defface org-transclusion
  '((((class color) (min-colors 88) (background light))
     :background "#ebf6fa" :extend t)
    (((class color) (min-colors 88) (background dark))
     :background "#041529" :extend t)
    (t ))
  "Face for transcluded region in the transcluding buffer."
  :group 'org-transclusion)

(defface org-transclusion-edit
  '((((class color) (min-colors 88) (background light))
     :background "#ebf6fa" :extend t)
    (((class color) (min-colors 88) (background dark))
     :background "#041529" :extend t)
    (t
     :background "forest green" :extend t))
  "Face for element in the transcluding buffer in the edit mode."
  :group 'org-transclusion)

;;;; Variables

(defvar-local org-transclusion-remember-point nil
  "This variable is used to remember the current just before `save-buffer'.
It is meant to be used to remember and return to the current
point after `before-save-hook' and `after-save-hook' pair;
`org-transclusion-before-save-buffer' and
`org-transclusion-after-save-buffer' use this variable.")

(defvar-local org-transclusion-before-save-transclusions nil
  "This variable is used to remember the active transclusions before `save-buffer'.
It is meant to be used to keep the file the current buffer is
visiting clear of the transcluded text content.  Instead of
blindly deactivate and activate all transclusions with t flag,
this variable is meant to provide mechanism to
deactivate/activate only the transclusions currently used to copy
a text content.

`org-transclusion-before-save-buffer' and
`org-transclusion-after-save-buffer' use this variable.")


(defvar-local org-transclusion-temp-window-config nil
  "Rember window config (the arrangment of windows) for the
  current buffer. This is for live-sync.

Analogous to `org-edit-src-code'.")

(defvar org-transclusion-yank-excluded-properties '(tc-id tc-type
                                                          tc-beg-mkr
                                                          tc-end-mkr
                                                          tc-src-beg-mkr
                                                          tc-pair
                                                          tc-orig-keyword
                                                          org-transclusion-text-beg-mkr
                                                          org-transclusion-text-end-mkr))

(defvar org-transclusion-yank-excluded-line-prefix nil)
(defvar org-transclusion-yank-excluded-wrap-prefix nil)

(defvar org-transclusion-line-search-handler '((paragraph . org-transclusion-paragraph-from-line)
					       (one-line . org-transclusion-one-line))
  "Alist of function to call when file link has a line search option,
determined by the value of `org-transclusion-line-search-style'
NOTE: All functions must return the range of the transclusion in a list
for example, the function `org-transclusion-one-line' return
the list of (BEG . END) in which, BEG is the the position of the first charracter
and END is the position of the last character of the current line.")

(defvar org-transclusion-link-open-hook
  '(org-transclusion-link-open-org-id
    org-transclusion-open-file-link))

(defvar org-transclusion-get-keyword-values-hook
  '(org-transclusion-keyword-get-value-active-p
    org-transclusion-keyword-get-value-link
    org-transclusion-keyword-get-value-level
    org-transclusion-keyword-get-current-indentation))

(defvar org-transclusion-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "e") #'org-transclusion-live-sync-start-at-point)
    (define-key map (kbd "g") #'org-transclusion-refresh-at-point)
    (define-key map (kbd "d") #'org-transclusion-remove-at-point)
    (define-key map (kbd "P") #'org-transclusion-promote-subtree)
    (define-key map (kbd "D") #'org-transclusion-demote-subtree)
    (define-key map (kbd "o") #'org-transclusion-open-source)
    (define-key map (kbd "TAB") #'org-cycle)
    map)
  "It is the local-map used within a transclusion.
As the transcluded text content is read-only, these keybindings
are meant to be a sort of contextual menu to trigger different
functions on the transclusion.")

(defvar org-transclusion-live-sync-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map org-mode-map)
    (define-key map (kbd "C-c C-c") #'org-transclusion-live-sync-exit-at-point)
    (define-key map (kbd "C-y") #'org-transclusion-live-sync-paste)
    map)
  "It is the local-map used within the live-sync overlay.
It inherits `org-mode-map' and adds a couple of org-transclusion
specific keybindings; namely:

- `org-transclusion-live-sync-paste'
- `org-transclusion-live-sync-exit-at-point'")


(define-fringe-bitmap 'org-transclusion-fringe-bitmap
  [#b11000000
   #b11000000
   #b11000000
   #b11000000
   #b11000000
   #b11000000
   #b11000000
   #b11000000]
  nil nil '(center t))

;;;; Flycheck warns with "macro X defined too late"
(defmacro org-transclusion-with-silent-modifications (&rest body)
  "Run BODY silently.
It's like `with-silent-modifications' but keeps the undo list."
  (declare (debug t) (indent 0))
  (let ((modified (make-symbol "modified")))
    `(let* ((,modified (buffer-modified-p))
            (inhibit-read-only t)
            (inhibit-modification-hooks t))
       (unwind-protect
           (progn
             ,@body)
         (unless ,modified
           (restore-buffer-modified-p nil))))))

;;;; Commands

(define-minor-mode org-transclusion-mode
  "Toggle Org-transclusion minor mode."
  :init-value nil
  :lighter nil
  :global nil
  :keymap (let ((map (make-sparse-keymap)))
            map)
  (cond
   (org-transclusion-mode
    (org-transclusion-activate)
    (when org-transclusion-add-all-on-activate
      (org-transclusion-add-all-in-buffer)))
   (t (org-transclusion-deactivate))))

(defun org-transclusion-activate ()
  "Activate automatic transclusions in the local buffer."
  (interactive)
  (add-hook 'before-save-hook #'org-transclusion-before-save-buffer nil t)
  (add-hook 'after-save-hook #'org-transclusion-after-save-buffer nil t)
  (add-hook 'kill-buffer-hook #'org-transclusion-before-kill nil t)
  (add-hook 'kill-emacs-hook #'org-transclusion-before-kill nil t)
  (org-transclusion-yank-excluded-properties-set))

(defun org-transclusion-deactivate ()
  "Deactivate automatic transclusions in the local buffer."
  (interactive)
  (org-transclusion-remove-all-in-buffer)
  (remove-hook 'before-save-hook #'org-transclusion-before-save-buffer t)
  (remove-hook 'after-save-hook #'org-transclusion-after-save-buffer t)
  (remove-hook 'kill-buffer-hook #'org-transclusion-before-kill t)
  (remove-hook 'kill-emacs-hook #'org-transclusion-before-kill t)
  (org-transclusion-yank-excluded-properties-remove))

(defun org-transclusion-make-from-link (&optional arg)
  "Make a transclusion keyword from a link at point.

The resultant transclusion keyword will be placed in the first
empty line.  If there is no empty line until the bottom of the
buffer, add a new empty line.

When `org-transclusion-mode' is active, this function automatically transclude
the text content; when it is inactive, it simply adds \"#+transclude t
[[link]]\" for the link.

You can pass a prefix argument (ARG) with using
`digit-argument' (e.g. C-1 or C-2; or \\[universal-argument] 3,
so on) or `universal-argument' (\\[universal-argument]).

If you pass a positive number 1-9 with `digit-argument', this function
automatically inserts the :level property of the resultant transclusion.

If you pass a `universal-argument', this function automatically triggers
transclusion by calling `org-transclusion-add-at-point'."
  ;; check if at-point is a link file or id
  (interactive "P")
  (let* ((context (org-element-lineage
                   (org-element-context)'(link) t))
         (type (org-element-property :type context)))
    (when (or (string= type "file")
              (string= type "id"))
      (let* ((contents-beg (org-element-property :contents-begin context))
             (contents-end (org-element-property :contents-end context))
             (contents (when contents-beg
                         (buffer-substring-no-properties contents-beg contents-end)))
             (link (org-element-link-interpreter context contents)))
        (save-excursion
          (org-transclusion-search-or-add-next-empty-line)
          (insert (format "#+transclude: t %s\n" link))
          (forward-line -1)
          (when (and (numberp arg)
                     (> arg 0)
                     (<= arg 9))
            (end-of-line)
            (insert (format " :level %d" arg)))
          (when (or (equal arg '(4)) org-transclusion-mode)
            (org-transclusion-add-at-point)))))))

(defun org-transclusion-add-at-point ()
  "Transclude text content where #+transclude at point points.

Examples of acceptable formats are as below:

- \"#+transclude: t[nil] [[file:path/file.org::search-option][desc]]:level n\"
- \"#+transclude: t[nil] [[id:uuid]] :level n\"

The file path or id are tranlated to the normal Org Mode link
format such as [[file:path/tofile.org::*Heading]] or [[id:uuid]]
to copy the text content of the link target.

TODO: id:uuid without brackets [[]] is a valid link within Org
Mode. This is not supported yet.

A transcluded text region is read-only, but you can activate the
live-sync edit mode by calling
`org-transclusion-live-sync-start-at-point'. This edit mode is
analogous to Occur Edit for Occur Mode.  As such, following keys
can be used on the read-only text within a transcluded region.

You can customize the keymap with using `org-transclusion-map':

\\{org-transclusion-map}"
  (interactive)
  (when-let* ((keyword-plist (org-transclusion-keyword-get-string-to-plist))
              (link (org-transclusion-wrap-path-to-link
                     (plist-get keyword-plist :link)))
              (type (org-element-property :type link)))
    ;; The transclusion needs to be active, and the link type needs to be
    ;; either id or file
    (cond ((and (plist-get keyword-plist :active-p)
                (or (string= "id" type)
                    (string= "file" type)))
           (let ((tc-params))
             (setq tc-params (run-hook-with-args-until-success
                              'org-transclusion-link-open-hook link))
             (if (not tc-params)
                 (progn (message (format
                                  "No transclusion added. Check the link at point %d, line %d"
                                  (point) (org-current-line)))
                        nil) ; return nil)
               (let* ((tc-type (plist-get tc-params :tc-type))
                      (tc-arg (plist-get tc-params :tc-arg))
                      (tc-fn (plist-get tc-params :tc-fn))
                      (tc-payload (funcall tc-fn tc-arg tc-type))
                      (tc-beg-mkr (plist-get tc-payload :tc-beg-mkr))
                      (tc-end-mkr (plist-get tc-payload :tc-end-mkr))
                      (tc-content (plist-get tc-payload :tc-content)))
                 (if (or (string= tc-content "")
                         (eq tc-content nil))
                     (progn (message
                             (format "Nothing done.  \
No content is found through the link at point %d, line %d"
                                     (point) (org-current-line)))
                            nil)
                   (org-transclusion-with-silent-modifications
                     ;; Insert & overlay
                     (when (save-excursion
                             (end-of-line) (insert-char ?\n)
                             (org-transclusion-content-insert
                              keyword-plist tc-type tc-content
                              tc-beg-mkr tc-end-mkr)
                             (delete-char 1)
                             t) ;; return t for "when caluse"
                       ;; Remove keyword after having transcluded content
                       (when (org-at-keyword-p)
                         (org-transclusion-keyword-remove))
                       (org-transclusion-activate))))))))
          ;; For other cases. Do nothing
          (t (message "Nothing done. Transclusion inactive or link missing at %d" (point))
             nil))))

(defun org-transclusion-add-all-in-buffer ()
  "Add all active transclusions in the current buffer."
  (interactive)
  (let ((pos (point)))
    (org-with-point-at 1
      (let ((regexp "^[ \t]*#\\+TRANSCLUDE:"))
        (while (re-search-forward regexp nil t)
          ;; Don't transclude if within a transclusion to avoid infinite
          ;; recursion
          (unless (org-transclusion--within-transclusion-p)
            (org-transclusion-add-at-point)))))
    (goto-char pos)
    t))

(defun org-transclusion-remove-at-point ()
  "Remove transcluded text at point.
When success, return the beginning point of the keyword re-inserted."
  (interactive)
  (if-let* ((beg (marker-position (get-char-property (point) 'tc-beg-mkr)))
            (end (marker-position (get-char-property (point) 'tc-end-mkr)))
            (keyword-plist (get-char-property (point) 'tc-orig-keyword))
            (indent (plist-get keyword-plist :current-indentation))
            (keyword (org-transclusion-keyword-plist-to-string keyword-plist))
            (tc-pair-ov (get-char-property (point) 'tc-pair)))
      (progn
        ;;(org-transclusion-live-sync-remove-overlays-maybe beg end)
        ;; Need to retain the markers of the other adjacent transclusions
        ;; if any.  If their positions differ after insert, move them back
        ;; beg or end
        (let ((mkr-at-beg
               ;; Check the points to look at exist in buffer.  Then look for
               ;; adjacent transclusions' markers if any.
               (when (>= (1- beg)(point-min))
                 (get-text-property (1- beg) 'tc-end-mkr))))
              ;; (mkr-at-end (when (<= (1+ end)(point-max))
              ;;               (get-text-property (1+ end) 'tc-beg-mkr))))
          (text-clone-delete-overlays)
          (delete-overlay tc-pair-ov)
          (outline-show-all)
          (org-transclusion-with-silent-modifications
            (save-excursion
              (delete-region beg end)
              (when (> indent 0) (indent-to indent))
              (insert-before-markers keyword))
            ;; Move markers of adjacent transclusions if any to their original
            ;; potisions.  Some markers move if two transclusions are placed
            ;; without any blank lines, and either of beg and end markers will
            ;; inevitably have the same position (location "between" lines)
            (when mkr-at-beg (move-marker mkr-at-beg beg))
            ;;(when mkr-at-end (move-marker mkr-at-end end))
            ;; Go back to the beginning of the inserted keyword line
            (goto-char beg))
          beg))
    (message "Nothing done. No transclusion exists here.") nil))

(defun org-transclusion-remove-all-in-buffer ()
  "Remove all transcluded text regions in the current buffer.
Return the list of points for the transclusion keywords re-inserted.
It is assumed that the list is ordered in descending order.
The list is intended to be used in `org-transclusion-before-save-buffer'."
  (interactive)
  (outline-show-all)
  (goto-char (point-min))
  (let ((point)(list))
    (while (text-property-search-forward 'tc-id)
      (forward-char -1)
      (org-transclusion-with-silent-modifications
        (setq point (org-transclusion-remove-at-point))
        (when point (push point list))))
    list))

(defun org-transclusion-refresh-at-point ()
  "Refresh the transcluded text at point."
  (interactive)
  (when (org-transclusion--within-transclusion-p)
    (let ((pos (point)))
      (org-transclusion-remove-at-point)
      (org-transclusion-add-at-point)
      (goto-char pos))
    t))

(defun org-transclusion-promote-subtree ()
  "Promote transcluded subtree at point."
  (interactive)
  (org-transclusion-promote-or-demote-subtree))

(defun org-transclusion-demote-subtree ()
  "Demote transcluded subtree at point."
  (interactive)
  (org-transclusion-promote-or-demote-subtree 'demote))

(defun org-transclusion-open-source (&optional arg)
  "Open the source buffer of transclusion at point.
When ARG is non-nil (e.g. \\[universal-argument]), the point will
remain in the source buffer for further editing."
  (interactive "P")
  (unless (overlay-buffer (get-text-property (point) 'tc-pair))
    (org-transclusion-refresh-at-point))
  (let* ((src-buf (overlay-buffer (get-text-property (point) 'tc-pair)))
         (tc-elem (org-transclusion-get-enclosing-element))
         (tc-beg (org-transclusion-element-get-beg-or-end 'beg tc-elem))
         (tc-end (org-transclusion-element-get-beg-or-end 'end tc-elem))
         (src-beg-mkr
          (or (org-transclusion-find-source-marker tc-beg tc-end)
              (get-text-property (point) 'tc-src-beg-mkr)))
         (buf (current-buffer)))
    (if (not src-buf)
        (user-error (format "No paired source buffer found here: at %d" (point)))
      (unwind-protect
          (progn
            (pop-to-buffer src-buf
                           '(display-buffer-reuse-window . '(inhibit-same-window)))
            (goto-char src-beg-mkr)
            (recenter-top-bottom))
        (unless arg (pop-to-buffer buf))))))

(defun org-transclusion-live-sync-start-at-point ()
  "Put overlay for start live sync edit on the transclusion at point.

While live sync is on, before- and after-save-hooks to remove/add
transclusions are also temporarily disabled.  This prevents
auto-save from getting in the way of live sync.

`org-transclusion-live-sync-map' inherits `org-mode-map' and adds
a couple of org-transclusion specific keybindings; namely:

- `org-transclusion-live-sync-paste'
- `org-transclusion-live-sync-exit-at-point'

\\{org-transclusion-live-sync-map}"
  (interactive)
  (if (not (org-transclusion--within-transclusion-p))
      (progn (message (format "Nothing done. Not a translusion at %d" (point)))
             nil)
    ;; Delete other live-sync overlays and clean-up.
    ;; There should be only one pair of transclusion-source in live-sync
    (when-let* ((deleted-live-sync-ovs (text-clone-delete-overlays))
                (deleted-tc-ov (cadr deleted-live-sync-ovs)))
      (org-transclusion-live-sync-after-delete-overlay deleted-tc-ov))
    (org-transclusion-refresh-at-point)
    (remove-hook 'before-save-hook #'org-transclusion-before-save-buffer t)
    (remove-hook 'after-save-hook #'org-transclusion-after-save-buffer t)
    (let* ((ovs (org-transclusion-live-sync-buffers-get))
           (src-ov (car ovs))
           (tc-ov (cdr ovs))
           (tc-beg (overlay-start tc-ov))
           (tc-end (overlay-end tc-ov)))
      (org-transclusion-live-sync-display-buffer (overlay-buffer src-ov))
      (org-transclusions-live-sync-modify-overlays (text-clone-set-overlays src-ov tc-ov))
      (with-silent-modifications
        (remove-text-properties (1- tc-beg) tc-end '(read-only)))
      t)))

(defun org-transclusion-live-sync-buffers-get ()
  "Return cons cell of overlays for source and trasnclusion.
    (src-ov . tc-ov)

This function looks at transclusion type (tc-type) property and
delegates the actual process to the specific function for the
type.

Assume this function is called with the point on an
org-transclusion overlay."
  (let ((type (get-text-property (point) 'tc-type))
	(parent (get-text-property (point) :parent)))
    (cond
     ;; Org Link and ID
     ((and (string-prefix-p "org" type 'ignore-case) parent)
      (org-transclusion-live-sync-buffers-get-org))
     (t (org-transclusion-live-sync-buffers-get-others-default)))))

(defun org-transclusion-live-sync-buffers-get-others-default ()
  "Return cons cell of overlays for source and trasnclusion.
    (src-ov . tc-ov)
This function is for non-Org text files."
  ;; Get the transclusion source's overlay but do not directly use it; it is
  ;; needed after exiting live-sync, which deletes live-sync overlays.
  (when-let* ((tc-pair (get-text-property (point) 'tc-pair))
              (src-ov (text-clone-make-overlay
                       (overlay-start tc-pair)
                       (overlay-end tc-pair)
                       (overlay-buffer tc-pair)))
              (tc-ov (text-clone-make-overlay
                      (get-text-property (point) 'tc-beg-mkr)
                      (get-text-property (point) 'tc-end-mkr))))
    (cons src-ov tc-ov)))

(defun org-transclusion-live-sync-buffers-get-org ()
  "Return cons cell of overlays for source and trasnclusion.
    (src-ov . tc-ov)
This function is for Org Links and IDs."
  (let* ((tc-elem (org-transclusion-get-enclosing-element))
         (tc-beg (org-transclusion-element-get-beg-or-end 'beg tc-elem))
         (tc-end (org-transclusion-element-get-beg-or-end 'end tc-elem))
         (src-range-mkrs (org-transclusion-live-sync-source-range-markers-get
                          tc-beg tc-end))
         (src-beg-mkr (car src-range-mkrs))
         (src-end-mkr (cdr src-range-mkrs))
         (src-buf (marker-buffer src-beg-mkr))
         (src-content (org-transclusion-live-sync-source-content-get
                       src-beg-mkr src-end-mkr))
         (src-ov (text-clone-make-overlay
                  src-beg-mkr src-end-mkr src-buf))
         (tc-ov))
    ;; Replace the region as a copy of the src-overlay region
    (save-excursion
      (let* ((inhibit-read-only t)
             (props)
             (m (get-text-property tc-beg 'tc-beg-mkr))
             (beg (marker-position m)))
        (goto-char tc-beg)
        (setq props (text-properties-at tc-beg))
        (delete-region tc-beg tc-end)
        (insert-and-inherit src-content)
        (setq tc-end (point))
        (add-text-properties tc-beg tc-end props)
        (move-marker m beg)))
    (setq tc-ov (org-transclusion-make-overlay tc-beg tc-end))
    (cons src-ov tc-ov)))

(defun org-transclusion-live-sync-exit-at-point ()
  "Exit live-sync at point.
It attemps to re-arrange the windows for the current buffer to
the state before live-sync started."
  (interactive)
  ;; Explicitly delete live-sync overlays.  Not functionally necessary as
  ;; refresh does this inside it; however, it will make the intention of this
  ;; function clearer.
  (text-clone-delete-overlays)
  ;; Re-activate hooks inactive during live-sync
  (org-transclusion-activate)
  (org-transclusion-refresh-at-point)
  (when org-transclusion-temp-window-config
    (unwind-protect
        (set-window-configuration org-transclusion-temp-window-config)
      (progn
        (setq org-transclusion-temp-window-config nil)))))

(defun org-transclusion-live-sync-paste ()
  "Paste text content from `kill-ring' and inherit the text props.
This is meant to be used within live-sync overlay.  This function
is meant to be used as part of `org-transclusion-live-sync-map'"
  (interactive)
  (insert-and-inherit (current-kill 0)))

;;;;-----------------------------------------------------------------------------
;;;; Functions for Activate / Deactiveate / save-buffer hooks

(defun org-transclusion-yank-excluded-properties-set ()
  "Set `yank-excluded-properties' for pasting transcluded text.
This way, the pasted text will not inherit the text props that
are required for live-sync and other transclusion-specific
functions.

`org-transclusion-yank-excluded-line-prefix' and
`org-transclusion-yank-excluded-wrap-prefix' are used to ensure
the settings revert to the user's setting prior to
`org-transclusion-activate'."
  ;; Ensure this happens only once until deactivation
  (unless (memq 'tc-id yank-excluded-properties)
    ;; Return t if 'wrap-prefix is already in `yank-excluded-properties'
    ;; if not push to elm the list
    (setq org-transclusion-yank-excluded-wrap-prefix
          (if (memq 'wrap-prefix yank-excluded-properties) t
            (push 'wrap-prefix yank-excluded-properties) nil))
    (setq org-transclusion-yank-excluded-line-prefix
          (if (memq 'line-prefix yank-excluded-properties) t
            (push 'line-prefix yank-excluded-properties) nil))
    (setq yank-excluded-properties
          (append yank-excluded-properties org-transclusion-yank-excluded-properties))))

(defun org-transclusion-yank-excluded-properties-remove ()
  "Remove transclusion-specific text props from `yank-excluded-properties'.
`org-transclusion-yank-excluded-line-prefix' and
`org-transclusion-yank-excluded-wrap-prefix' are used to ensure
the settings revert to the user's setting prior to
`org-transclusion-activate'."
  (when (memq 'tc-id yank-excluded-properties)
    ;; Ensure it's called only once until next activation
    (dolist (obj org-transclusion-yank-excluded-properties)
      ;; 'line-prefix and 'wrap-prefix need to be set to the user's set values
      (setq yank-excluded-properties (delq obj yank-excluded-properties)))
    ;; Ensure `yank-excluded-properties' will revert to the user's setting
    ;; for line-prefix and wrap-prefix
    (unless  org-transclusion-yank-excluded-line-prefix
      (setq yank-excluded-properties
            (delq 'line-prefix yank-excluded-properties)))
    (unless org-transclusion-yank-excluded-wrap-prefix
      (setq yank-excluded-properties
            (delq 'wrap-prefix yank-excluded-properties)))))

(defun org-transclusion-before-save-buffer ()
  "."
  (setq org-transclusion-before-save-transclusions nil)
  (setq org-transclusion-remember-point (point))
  (setq org-transclusion-before-save-transclusions
        (org-transclusion-remove-all-in-buffer)))

(defun org-transclusion-after-save-buffer ()
  "."
  (unwind-protect
      (progn
        ;; Assume the list is in descending order.
        ;; pop and do from the bottom of buffer
        (dolist (p org-transclusion-before-save-transclusions)
          (save-excursion
            (goto-char p)
            (org-transclusion-add-at-point)))
        (when org-transclusion-remember-point
          (goto-char org-transclusion-remember-point))
    (progn
      (setq org-transclusion-remember-point nil)
      (setq org-transclusion-before-save-transclusions nil)))))

(defun org-transclusion-before-kill ()
  "."
  (org-transclusion-remove-all-in-buffer)
  (set-buffer-modified-p t)
  (save-buffer))

;;;;-----------------------------------------------------------------------------
;;;; Functions for Transclude Keyword
;;   #+transclude: t "~/path/to/file.org::1234"

(defun org-transclusion-keyword-get-string-to-plist ()
  "Return the \"#+transcldue:\" keyword's values if any at point."
  (save-excursion
    (beginning-of-line)
    (let ((plist))
      (when (string= "TRANSCLUDE" (org-element-property :key (org-element-at-point)))
        ;; #+transclude: keyword exists.
        ;; Further checking the value
        (when-let ((str (org-element-property :value (org-element-at-point))))
          (dolist (fn org-transclusion-get-keyword-values-hook) plist
                  (setq plist (append plist (funcall fn str)))))
        plist))))

(defun org-transclusion-keyword-get-value-active-p (string)
  "It is a utility function used converting a keyword STRING to plist.
It is meant to be used by `org-transclusion-get-string-to-plist'.
It needs to be set in
`org-transclusion-get-keyword-values-hook'."
  (when (string-match "^\\(t\\|nil\\).*$" string)
    (list :active-p (org-transclusion--not-nil (match-string 1 string)))))

(defun org-transclusion-keyword-get-value-link (string)
  "It is a utility function used converting a keyword STRING to plist.
It is meant to be used by
`org-transclusion-get-string-to-plist'.  It needs to be set in
`org-transclusion-get-keyword-values-hook'."
  (if (string-match "\\(\\[\\[.+?\\]\\]\\)" string)
      (list :link (org-strip-quotes (match-string 0 string)))
    ;; link mandatory
    (user-error "Error.  Link in #+transclude is mandatory at %d" (point))
    nil))

(defun org-transclusion-keyword-get-value-level (string)
  "It is a utility function used converting a keyword STRING to plist.
It is meant to be used by `org-transclusion-get-string-to-plist'.
It needs to be set in
`org-transclusion-get-keyword-values-hook'."
  (when (string-match ":level *\\([1-9]\\)" string)
    (list :level (string-to-number (org-strip-quotes (match-string 1 string))))))

(defun org-transclusion-keyword-get-current-indentation (_)
  "It is a utility function used converting a keyword STRING to plist.
It is meant to be used by `org-transclusion-get-string-to-plist'.
It needs to be set in
`org-transclusion-get-keyword-values-hook'."
  (list :current-indentation (current-indentation)))

(defun org-transclusion-keyword-remove ()
  "Remove the keyword element at point.
It assumes that point is at a keyword."
  (let* ((elm (org-element-at-point))
         (beg (org-element-property :begin elm))
         (end (org-element-property :end elm))
         (post-blank (org-element-property :post-blank elm)))
    (delete-region beg (- end post-blank)) t))

(defun org-transclusion-keyword-plist-to-string (plist)
  "Convert a keyword PLIST to a string."
  (let ((active-p (plist-get plist :active-p))
        (link (plist-get plist :link))
        (level (plist-get plist :level)))
    (concat "#+transclude: "
            (symbol-name active-p)
            " " link
            (when level (format " :level %d" level))
            "\n")))

;;;;-----------------------------------------------------------------------------
;;;; Functions for inserting content
(defun org-transclusion-content-insert (keyword-values type content src-beg-m src-end-m)
  "Add content and overlay.
- KEYWORD-VALUES :: TBD
- TYPE :: TBD
- CONTENT :: TBD
- SRC-BEG-M :: TBD
- SRC-END-M :: TBD."
  (let* ((tc-id (substring (org-id-uuid) 0 8))
         (sbuf (marker-buffer src-beg-m)) ;source buffer
         (beg (point)) ;; before the text is inserted
         (beg-mkr)
         (end) ;; at the end of text content after inserting it
         (end-mkr)
         (ov-src) ;; source-buffer
         (tc-pair))
    (when (org-kill-is-subtree-p content)
      (let ((level (plist-get keyword-values :level)))
        (with-temp-buffer
          ;; This temp buffer needs to be in Org Mode
          ;; Otherwise, subtree won't be recognized as a Org subtree
          (delay-mode-hooks (org-mode))
          (org-paste-subtree level content t nil)
          (setq content (buffer-string)))))
    (insert (org-transclusion-content-format content))
    (setq beg-mkr (save-excursion (goto-char beg)
                                  (set-marker (make-marker) (point))))
    (setq end (point))
    (setq end-mkr (save-excursion (goto-char end)
                                  (set-marker (make-marker) (point))))
    (setq ov-src (org-transclusion-make-overlay src-beg-m src-end-m sbuf))
    (setq tc-pair ov-src)
    (add-text-properties beg end
                         `(local-map ,org-transclusion-map
                                     read-only t
                                     front-sticky t
                                     ;; rear-nonticky seems better for
                                     ;; src-lines to add "#+result" after C-c
                                     ;; C-c
                                     rear-nonsticky t
                                     tc-id ,tc-id
                                     tc-type ,type
                                     tc-beg-mkr ,beg-mkr
                                     tc-end-mkr ,end-mkr
                                     tc-src-beg-mkr ,src-beg-m
                                     tc-pair ,tc-pair
                                     tc-orig-keyword ,keyword-values
                                     ;; TODO Fringe is not supported for terminal
                                     line-prefix ,(org-transclusion-propertize-transclusion)
                                     wrap-prefix ,(org-transclusion-propertize-transclusion)))
    ;; Put to the source overlay
    (overlay-put ov-src 'tc-by beg-mkr)
    (overlay-put ov-src 'evaporate t)
    (overlay-put ov-src 'line-prefix (org-transclusion-propertize-source))
    (overlay-put ov-src 'wrap-prefix (org-transclusion-propertize-source))
    (overlay-put ov-src 'priority -50)
    (overlay-put ov-src 'tc-pair tc-pair)
    t))

(defun org-transclusion-content-format (content)
  "Format text CONTENT from source before transcluding.
Return content modified (or unmodified, if not applicable).
Currently it only re-aligns table with links in the content."
  (with-temp-buffer
    (org-mode)
    (insert content)
    ;; Fix table alignment
    (let ((point (point-min)))
      (while point
        (goto-char (1+ point))
        (when (org-at-table-p)
          (org-table-align)
          (goto-char (org-table-end)))
        (setq point (search-forward "|" (point-max) t))))
    ;; Fix indentation when `org-adapt-indentation' is non-nil
    (org-indent-region (point-min) (point-max))
    ;; Return the temp-buffer's string
    (buffer-string)))

(defun org-transclusion-link-open-org-id (link)
  "Return a list for Org-ID LINK object.
Return nil if not found."
  (when (string= "id" (org-element-property :type link))
    ;; when type is id, the value of path is the id
    (let* ((id (org-element-property :path link))
           (mkr (ignore-errors (org-id-find id t))))
      (if mkr
          (list :tc-type "org-id"
                :tc-arg mkr
                :tc-fn #'org-transclusion-content-get-from-org-marker)
        (message (format "No transclusion done for this ID. Ensure it works at point %d, line %d"
                         (point) (org-current-line)))
        nil))))

(defun org-transclusion-open-file-link (link)
  "Return a list for file LINK object.
Return nil if not found."
  (let ((path (org-element-property :path link)))
    (when (file-exists-p path) ;; Check if file exists
      (list :tc-type
	    (if (org-transclusion--org-file-p path) 
		"org-link" ;; Special value for handling org file
	      (org-element-property :type link)) ;; for non-org file
	    :tc-arg link
	    :tc-fn #'org-transclusion-content-get-from-file-link))))

;; (defun org-transclusion-link-open-org-file-links (link)
;;   "Return a list for Org file LINK object.
;; Return nil if not found."
;;   (when (org-transclusion--org-file-p (org-element-property :path link))
;;     (list :tc-type "org-link"
;;           :tc-arg link
;;           :tc-fn #'org-transclusion-content-get-from-org-link)))

;; (defun org-transclusion-link-open-other-file-links (link)
;;   "Return a list for non-Org file LINK object.
;; Return nil if not found."
;;   (org-transclusion--get-custom-tc-params link))

(defun org-transclusion-content-get-from-org-marker (marker)
  "Return tc-beg-mkr, tc-end-mkr, tc-content from MARKER.
This is meant for Org-ID."
  (if (and marker (marker-buffer marker)
           (buffer-live-p (marker-buffer marker)))
      (progn
        (with-current-buffer (marker-buffer marker)
          (org-with-wide-buffer
           ;;(outline-show-all)
           (goto-char marker)
           (if (org-before-first-heading-p)
               (org-transclusion-content-get-org-buffer-or-element-at-point)
             (org-transclusion-content-get-org-buffer-or-element-at-point 'only-element)))))
    (message "Nothing done. Cannot find marker for the ID.")))

;; (defun org-transclusion-content-get-from-org-link (link &rest _arg)
;;   "Return tc-beg-mkr, tc-end-mkr, tc-content from LINK."
;;   (save-excursion
;;     ;; First visit the buffer and go to the relevant elelement if id or
;;     ;; search-option is present.
;;     (let* ((path (org-element-property :path link))
;;            (search-option (org-element-property :search-option link))
;;            (buf (find-file-noselect path)))
;;       (with-current-buffer buf
;;         (org-with-wide-buffer
;;          ;;(outline-show-all)
;;          (if search-option
;;              (progn
;;                (org-link-search search-option)
;;                (org-transclusion-content-get-org-buffer-or-element-at-point 'only-element))
;;            (org-transclusion-content-get-org-buffer-or-element-at-point)))))))

(defun org-transclusion-content-get-from-file-link (link &optional type)
  "Return tc-beg-mkr, tc-end-mkr, tc-content from file LINK."
  (save-excursion
    ;; First visit the buffer and go to the relevant elelement if id or
    ;; search-option is present.
    (let* ((path (org-element-property :path link))
	   (file-type (or type (org-element-property :type link)))
           (search-option (org-element-property :search-option link)))
      (if (file-exists-p path) ;; Check if file exists,
	  (with-current-buffer (find-file-noselect path) ;; if yes, open file in another buffer
	    (org-with-wide-buffer ;; Call `org-transclusion-content-get-buffer-or-element-at-point'
	     (apply #'org-transclusion-content-get-buffer-or-element
		      link
		      ;; Start constructing arguments 
		      (string-match-p "org-link" file-type) ;; Check if this is an org file.
		      search-option ;; Having search option implies non-nil only-element argument.
		      (cond ((not search-option) nil) ;; No search options, invoke right away, yields whole buffer.
			    ((string-match-p "\\`[0-9]+\\'" search-option) ;; Check if option is for line,
			     (list (string-to-number search-option))) ;; invoke with option as line-num argument
			    ;; Pass other kinds of options as search-option argument
			    (t (list nil search-option))))))
	;; File doesn't exist
	(user-error "%s" (concat path " doesn't exist!"))))))

(defun org-transclusion-regexp-search-default (regexp)
  "Match the last occurance of REGEXP in current buffer."
  (save-excursion
    (goto-char (point-max))
    (re-search-backward regexp nil t)))

(defun org-transclusion-one-line (&optional line-num)
  "Returns (BEG END) with the position of the first and last character of LINE-NUM,
or the current line if LINE-NUM is nil, as BEG and END respectively."
  (save-excursion
    (when line-num
      (goto-line line-num))
    (list (line-beginning-position) (line-end-position))))

(defun org-transclusion-paragraph-from-line (&optional line-num)
  "Returns (BEG END) with the position of the beginning and end of a paragraph at LINE-NUM,
or the current line if LINE-NUM is nil, as BEG and END respectively."
  (save-excursion
    (when line-num
      (goto-line line-num))
    (list
     (save-excursion (backward-paragraph)
		     (point))
     (save-excursion (forward-paragraph)
		     (point)))))
    
(defun org-transclusion-content-get-org-buffer-or-element-at-point (&optional only-element)
  "Return content for transclusion.
When ONLY-ELEMENT is t, only the element.  If nil, the whole buffer.
Assume you are at the beginning of the org element to transclude."
  (let* ((el (org-element-context))
         (type (when el (org-element-type el))))
    (if (or (not el)(not type))
        (message "Nothing done")
      ;; For dedicated target, we want to get the parent paragraph,
      ;; rather than the target itself
      (when (and (string= "target" type)
                 (string= "paragraph" (org-element-type (org-element-property :parent el))))
        (setq el (org-element-property :parent el)))
      (let ((no-recursion '(headline section))
            (tc-content)(tc-beg-mkr)(tc-end-mkr)(tree)(obj))
        (when only-element (push type no-recursion))
        (setq tree (if (not only-element)
                       (org-element-parse-buffer)
                     (org-element--parse-elements
                      (org-element-property :begin el)
                      (org-element-property :end el)
                      nil nil 'object nil (list 'tc-paragraph nil))))
        (setq obj (org-element-map
                      tree
                      org-element-all-elements
                    ;; Map all the elements (not objects).  But for the
                    ;; output (transcluded copy) do not do recursive for
                    ;; headline and section (as to avoid duplicate
                    ;; sections; headlines contain section) Want to remove
                    ;; the elements of the types included in the list from
                    ;; the AST.
                    #'org-transclusion-content-filter-org-buffer
                    nil nil no-recursion nil))
        (setq tc-content (org-element-interpret-data obj))
        (setq tc-beg-mkr (progn (goto-char
                                 (if only-element (org-element-property :begin el)
                                   (point-min))) ;; for the entire buffer
                                (point-marker)))
        (setq tc-end-mkr (progn (goto-char
                                 (if only-element (org-element-property :end el)
                                   (point-max))) ;; for the entire buffer
                                (point-marker)))
        (list :tc-content tc-content
              :tc-beg-mkr tc-beg-mkr
              :tc-end-mkr tc-end-mkr)))))

(defun org-transclusion-content-get-buffer-or-element (link &optional org-p only-element line-num search-option)
  "Return content for transclusion.
When ONLY-ELEMENT is t, only the element.  If nil, the whole buffer.
LINE-NUM and SEARCH-OPTION are from `org-transclusion-content-get-from-file-link', 
both implies that ONLY-ELEMENT is t.

A non-nil LINE-NUM is passed to the function of `org-transclusion-line-search-handler',
the function returns a range, range of the content for transclusion.
A non-nil SEARCH-OPTION return only the element, that the search matches."
  (save-excursion
    (let* ((search-string (when search-option
			   ;; Extract "REGEXP" from "/REGEXP/"
			   (if (string-match "/\\(.*\\)/" search-option)
		     	       (match-string 1 search-option)
			     search-option)))
	  (content-range ;; In the forms of (BEG END)
	   (cond
	    ((not only-element) (list (point-min) (point-max))) ;; If only-element is nil, returns the range is the whole buffer.
	    ;; if line-num is non-nil, returns the evaluation from one of 'org-transclusion-line-search-handler' function.
	    (line-num (funcall (alist-get org-transclusion-line-search-style org-transclusion-line-search-handler) line-num))
	    ;; if search-option is non-nil, return the match data.
	    (search-option
	     (cond
      	      ;; When this is an org file with no line search or regexp search call `org-link-search' with search option
	      ((and org-p (not line-num) (not (string-match "/\\(.*\\)/" search-option))) (org-link-search search-string))
	      ;; When search-option doesn't match, show error.
	      ((zerop (how-many search-string)) (user-error "Nothing matched %s in %s" search-option (buffer-file-name)))
	      ;; Or else, handle regexp with `org-transclusion-regexp-search-function'
	      (t (save-match-data
		   (funcall org-transclusion-regexp-search-function (concat search-string ".*"))
		   (match-data))))))))
      (cond
       ;; If this is an org file and no search option, get the whole buffer.
       ((and org-p (not only-element))
	(org-transclusion-content-get-org-buffer-or-element-at-point nil))
       ;; If this is an org file, no line-num and search option is org-specific, get only that element
       ((and org-p (not line-num) (not (string-match "/\\(.*\\)/" search-option)))
	(org-transclusion-content-get-org-buffer-or-element-at-point t))
       (t
	;; If this is non-org file or an org file with other kind of search option.
	(progn (let* ((tc-content)(tc-beg-mkr)(tc-end-mkr)) ;; Assign empty variables
		 ;; tc-beg-mkr and tc-end-mkr is the range of the content for transclusion.
		 ;; When ONLY-ELEMENT is nil, tc-beg-mkr and tc-end-mkr is the range of the whole buffer.
		 ;; When LINE-NUM is non-nil, tc-beg-mkr and tc-end-mkr is determined by
		 ;; `org-transclusion-line-search-handler'
		 ;; When SEARCH-OPTION is non-nil, the range is the beginning and end
		 ;; of what matches the regular expression.
		 (setq tc-beg-mkr (progn (goto-char (car content-range)) (point-marker)))
		 (setq tc-end-mkr (progn (goto-char (cadr content-range)) (point-marker)))
		 (setq tc-content (buffer-substring tc-beg-mkr tc-end-mkr))
		 (list :tc-content tc-content
		       :tc-beg-mkr tc-beg-mkr
		       :tc-end-mkr tc-end-mkr))))))))

(defun org-transclusion-content-filter-org-buffer (data)
  "Filter DATA before transcluding its content.
DATA is meant to be a parse tree for ‘org-element.el'.

This function is used within
`org-transclusion-content-get-org-buffer-or-element-at-point'.

Use `org-transclusion-exclude-elements' variable to specify which
elements to remove from the transcluded copy.

The \"first section\" (the part before the first headline) is by
default excluded -- this is the intended behavior.

Use `org-transclusion-include-first-section' customizing variable
to include the first section."
  (cond ((and (memq (org-element-type data) '(section))
              (not (eq 'tc-paragraph (org-element-type (org-element-property :parent data)))))
         ;; This condition is meant to filter out the first section; that is,
         ;; the part before the first headline.  The DATA should have the type
         ;; `org-data' by default, with one exception.  I put `tc-paragraph'
         ;; as the type when a paragraph is parased (via dedicated target).
         ;; In this case, the whole DATA should be returned.
         ;; Sections are included in the headlines Thies means that if there
         ;; is no headline, nothing gets transcluded.
         (if org-transclusion-include-first-section
             ;; Add filter to the first section as well
             (progn (org-element-map data org-transclusion-exclude-elements
                      (lambda (d) (org-element-extract-element d)))
                    data)
           nil))
        ;; Rest of the case.
        (t (org-element-map data org-transclusion-exclude-elements
             (lambda (d) (org-element-extract-element d) nil))
           data)))

;;;;-----------------------------------------------------------------------------
;;;; Functions to support non-Org-mode link types

(defun org-transclusion--get-custom-tc-params (link)
  "Return PARAMS with TC-FN if link type is supported for LINK object."
  (let ((types org-transclusion-add-at-point-functions)
        (params nil)
        (str nil))
    (setq str (org-element-property :path link))
    (while (and (not params)
                types)
      (let* ((type (pop types))
             (match-fn
              (progn (intern (concat "org-transclusion--match-" type))))
             (add-fn
              (progn (intern (concat "org-transclusion--add-" type)))))
        (when (and (functionp match-fn)
                   (funcall match-fn str)
                   (functionp add-fn))
          (setq params (list :tc-type type :tc-fn add-fn :tc-arg str)))))
    params))

(defun org-transclusion--match-others-default (_path)
  "Check if `others-default' can be used for the PATH.
Returns non-nil if check is pass."
  t)

;; (defun org-transclusion--add-others-default (path)
;;   "Use PATH to return TC-CONTENT, TC-BEG-MKR, and TC-END-MKR.
;; TODO need to handle when the file does not exist."
;;   (let ((buf (find-file-noselect path)))
;;     (with-current-buffer buf
;;       (org-with-wide-buffer
;;        (let ((content (buffer-string))
;;              (beg (point-min-marker))
;;              (end (point-max-marker)))
;;          (list :tc-content content
;;                :tc-beg-mkr beg
;;                :tc-end-mkr end))))))

;;-----------------------------------------------------------------------------
;;; Utility Functions

(defun org-transclusion-make-overlay (beg end &optional buf)
  "Wrapper for make-ovelay.
BEG and END can be point or marker.  Optionally BUF can be passed.
FRONT-ADVANCE is nil, and REAR-ADVANCE is t."
  (make-overlay beg end buf nil t))

(defun org-transclusion-find-source-marker (beg end)
  "Return marker that points to source begin point for transclusion.
It works on the transclusion region at point.  BEG and END are
meant to be transclusion region's begin and end used to limit the
`text-property-search' -- as it does not have an argument to
limit the search, this is done by looking at the output point and
compare it with BEG and END.

Return nil when :parent text-prop cannot be found.

This function critically relies on the fact that `org-element'
puts a \":parent\" text property to the elements obtained by
using `org-element-parse-buffer' and
`org-element--parse-elements' Some elements such as comment-block
does not seem to add :parent, which makes live-sync not working
for them.

Text properties are addeb by `org-element-put-property' which in
turn uses `org-add-props' macro. If any of this substantially
changes, the logic in this function will need to reviewed."
  (let ((parent (get-text-property (point) ':parent))
        (src-buf (marker-buffer
                  (get-text-property (point) 'tc-src-beg-mkr)))
        (m))
    (unless parent
      (save-excursion
        (when-let ((match (or (text-property-search-forward
                               ':parent)
                              (text-property-search-backward
                               ':parent))))
          ;; Point must be between beg and end (inclusive)
          (when (and (<= beg (point)) (<= (point) end))
            (setq parent (prop-match-value match))))))
    (when parent
      (setq m (set-marker (make-marker)
                          (or (org-element-property :contents-begin parent)
                              (org-element-property :begin parent))
                          src-buf)))
    m))

(defun org-transclusion-search-or-add-next-empty-line ()
  "Search the next empty line.
Start with the next line.  If the current line is the bottom of
the line, add a new empty line."
  ;; beginning-of-line 2 moves to the next line if possible
  (beginning-of-line 2)
  (if (eobp)(insert "\n")
    (while (not (looking-at-p "[ \t]*$"))
      (beginning-of-line 2))
    (if (eobp)(insert "\n"))))

(defun org-transclusion-wrap-path-to-link (path)
  "Return Org link object for PATH string."
  (with-temp-buffer
    (delay-mode-hooks (org-mode))
    (insert path)
    (org-element-context)))

(defun org-transclusion--org-file-p (path)
  "Return non-nil if PATH is an Org file.
Checked with the extension `org'."
  (let ((ext (file-name-extension path)))
    (string= ext "org")))

(defun org-transclusion--not-nil (v)
  "Return t or nil.
It is like `org-not-nil', but when the V is non-nil or not
string \"nil\", return symbol t."
  (when (org-not-nil v) t))

(defun org-transclusion--within-transclusion-p ()
  "Return t if the current point is within a tranclusion overlay."
  (when (get-char-property (point) 'tc-id) t))

;; Looks like this is not needed for the purpose.
;; (defun org-transclusion--make-marker (point)
;;   "Return marker of the insertion-type t for POINT.
;; The insertion-type is important in order for the translusion
;; end marker is correctly set.  This fixes the problem of
;; transclude keyword not correctly removed when the keywords are
;; placed without a blank line."
;;   (let ((marker (set-marker (make-marker) point)))
;;     (set-marker-insertion-type marker t)
;;     marker))

(defun org-transclusion-propertize-transclusion ()
  "."
  (if (not (display-graphic-p))
      (propertize "| " 'face 'org-transclusion)
    (propertize
     "x"
     'display
     '(left-fringe org-transclusion-fringe-bitmap
                   org-transclusion-fringe))))

(defun org-transclusion-propertize-source ()
  "."
  (if (not (display-graphic-p))
      (propertize "| " 'face 'org-transclusion-source)
    (propertize
     "x"
     `display
     `(left-fringe empty-line
                   org-transclusion-source-fringe))))

;;-----------------------------------------------------------------------------
;;;; Functions for live-sync

(defun org-transclusion-live-sync-source-range-markers-get (beg end)
  "Find and return source range based on transclusion's BEG and END.
Return \"(src-beg-mkr . src-end-mkr)\"."
  (let ((src-buf (overlay-buffer (get-text-property (point) 'tc-pair)))
        (src-search-beg (org-transclusion-find-source-marker beg end)))
    (if (not src-search-beg)
        (user-error "No live-sync can be started at: %d" (point))
      (with-current-buffer src-buf
        (goto-char src-search-beg)
        (when-let* ((src-elem (org-transclusion-get-enclosing-element))
                    (src-beg (org-transclusion-element-get-beg-or-end 'beg src-elem))
                    (src-end (org-transclusion-element-get-beg-or-end 'end src-elem)))
          (cons
           (set-marker (make-marker) src-beg)
           (set-marker (make-marker) src-end)))))))

(defun org-transclusion-live-sync-source-content-get (beg end)
  "Return text content between BEG and END.
BEG and END are assumed to be markers for the transclusion's source buffer."
  (when (markerp beg)
    (with-current-buffer (marker-buffer beg)
      (buffer-substring-no-properties beg end))))

(defun org-transclusions-live-sync-modify-overlays (overlays)
  "Add overlay properties specific Org-transclusion for OVERLAYS.
This must be done after `text-clone-set-overlays'.
Org-transclusion always works with a pair of overlays."
  (let ((src-ov (car overlays))
        (tc-ov (cadr overlays)))
    ;; Source Overlay
    (overlay-put src-ov 'face 'org-transclusion-source-edit)
    ;; Transclusion Overlay
    (overlay-put tc-ov 'face 'org-transclusion-edit)
    (overlay-put tc-ov 'local-map org-transclusion-live-sync-map)))

(defun org-transclusion-get-enclosing-element ()
  "Return an enclosing Org element for live-sync.
This assumes the point is within the element (at point).

This function first looks for the following elements:

  center-block drawer dynamic-block example-block export-block
  fixed-width latex-environment plain-list property-drawer
  quote-block special-block table verse-block

If none of them found, this function identifies the paragraph at
point to return.

*comment-block, src-block, keyword do not work well as they
 don't seem t have :parent prop from `org-element'.

This function works in a temporary org buffer to isolate the
transcluded region and source region from the rest of the
original buffer.  This is required especially when translusion is
for a paragraph, which can be right next to another paragraph
without a blank space; thus, subsumed by the surrounding
paragraph."
  (let* ((beg (or (when-let ((m (get-char-property (point) 'tc-beg-mkr)))
                    (marker-position m))
                  (overlay-start (get-char-property (point) 'tc-pair))))
         (end (or (when-let ((m (get-char-property (point) 'tc-end-mkr)))
                    (marker-position m))
                  (overlay-end (get-char-property (point) 'tc-pair))))
         (content (buffer-substring beg end))
         (pos (point)))
    (if (or (not content)
            (string= content ""))
        (user-error (format "Live sync cannot start here: point %d" (point)))
      (with-temp-buffer
        (delay-mode-hooks (org-mode))
        ;; Calibrate the start position "Move" to the beg - 1 (buffer position
        ;; with 1, not 0)
        (insert-char ?\n (1- beg))
        (insert content)
        (goto-char pos)
        (let ((context
               (or (org-element-lineage (org-element-context)
                                        '(center-block
                                          ;; comment-block
                                          drawer
                                          dynamic-block
                                          example-block
                                          export-block fixed-width
                                          ;; keyword
                                          latex-environment
                                          plain-list
                                          property-drawer
                                          quote-block special-block
                                          ;; src-block
                                          table
                                          verse-block) 'with-self)
                   ;; For a paragraph
                   (org-element-lineage
                    (org-element-context) '(paragraph) 'with-self))))
          (if context context
            (user-error (format "Live sync cannot start here: point %d"
                                (point)))))))))

(defun org-transclusion-element-get-beg-or-end (beg-or-end element)
  "Return appropriate beg-or-end of an element.
This for when we need to find exactly the same sets of beg and
end for source and transclusion elements (e.g. live-sync).

Call BEG-OR-END passing either 'beg or 'end and the ELEMENT in
question.

We are usually interested in :contents-begin and :contents-end,
but some greater elements such as src-block do not have them.  In
that case, we use :begin and :end.  The :end prop needs to be too
large; we need to sutract :post-blank from it.  All these props
are integers (points or number of blank lines.)"
  (let ((val
         (if (eq beg-or-end 'beg)
             (if-let ((val (org-element-property :contents-begin element)))
                 val
               (org-element-property :begin element))
           (when (eq beg-or-end 'end)
             (if-let ((val (org-element-property :contents-end element)))
                 val
               (- (org-element-property :end element)
                  (org-element-property :post-blank element)))))))
    val))

(defun org-transclusion-live-sync-after-delete-overlay (list)
  "Refresh the transclusion after live-sync has ended before
starting a new one.  LIST is assumed to be a list that represents
the deleted overlay for transclusion in this structure:

    (buf (beg . end))"
  (when list
    (let ((buf (car list))
          (beg (caadr list))
          (current-p (point)))
      (with-current-buffer buf
        (org-with-wide-buffer
         (goto-char beg)
         (org-transclusion-refresh-at-point))
        (goto-char current-p)))))

(defun org-transclusion-live-sync-display-buffer (buffer)
  "Display the source buffer upon entering live-sync edit.
It rembembers the current arrangement of windows (window
configuration), deletes the other windows, and displays
BUFFER (intended to be the source buffer being edited in
live-sync.)

This is analogous to `org-edit-src-code' -- by default, it
layouts the edit and original buffers side-by-side.

Upon exiting live-sync,
`org-transclusion-live-sync-exit-at-point' attempts to bring
back the original window configuration."
  (setq org-transclusion-temp-window-config (current-window-configuration))
  (delete-other-windows)
  (let ((win (selected-window)))
    (pop-to-buffer buffer
                   '(display-buffer-pop-up-window . '(inhibit-same-window)))
    (recenter-top-bottom)
    (select-window win)))

;;-----------------------------------------------------------------------------
;;;; Functions for promote/demote a transcluded subtree

(defun org-transclusion-promote-adjust-after ()
  "Adjust the level information after promote/demote."
  ;; find tc-beg-mkr. If the point is directly on the starts, you need to find
  ;; it in the headline title.
  ;; Assume point at beginning of the subtree after promote/demote
  (let* ((pos (next-property-change (point) nil (line-end-position)))
         (keyword-plist (get-text-property pos 'tc-orig-keyword))
         (level (car (org-heading-components))))
    ;; adjust keyword :level prop
    (setq keyword-plist (plist-put keyword-plist :level level))
    (put-text-property (point) (line-end-position) 'tc-orig-keyword keyword-plist)
    ;; refresh to get the text-prop corrected.
    (save-excursion
      (goto-char pos)
      (org-transclusion-refresh-at-point))))

(defun org-transclusion-promote-or-demote-subtree (&optional demote)
  "Promote or demote transcluded subtree.
When DEMOTE is non-nil, demote."
  (if (not (org-transclusion--within-transclusion-p))
      (message "Not in a transcluded headline.")
    (let ((inhibit-read-only t)
          (beg (get-text-property (point) 'tc-beg-mkr)))
      (let ((pos (point)))
        (save-excursion
          (goto-char beg)
          (when (org-at-heading-p)
            (if demote (org-demote-subtree) (org-promote-subtree))
            (org-transclusion-promote-adjust-after)))
        (goto-char pos)))))

(provide 'org-transclusion)
;;; org-transclusion.el ends here
