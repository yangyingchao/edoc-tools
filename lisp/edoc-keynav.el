;;; edoc-keynav.el --- Keyboard navigation for PDF files -*- lexical-binding: t; -*-
;; * Preamble

;; Copyright (C) 2022 orgtre <orgtre\a.t/posteo.net>

;; Author: orgtre <orgtre\a.t/posteo.net>
;; Created: 2021-08-17
;; Keywords: multimedia, files

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This minor mode for edoc-tools introduces standard-Emacs-like concepts of
;; point, mark, region, and cursor into edoc-tools and uses these to implement
;; keyboard-based navigation, selection, and annotation in pdf files.

;; Point is a special position on a pdf page. For simplicity, it is referred to
;; by an integer 'i', but point is at 'i' actually means that point is at the
;; midpoint of the left edge of the bounding rectangle of the character with
;; index 'i' in the list of characters and character boundaries on the current
;; pdf page. Mark is defined in the same way. The buffer-local variable
;; `edoc-keynav-charlayout' is this list of characters and character boundaries.
;; `edoc-keynav-point' stores point in terms of an index in it, while
;; `edoc-keynav-mark' does the same for mark. The region is the area of (the
;; bounding rectangles of) the characters between mark and point. Finally, the
;; cursor visually indicates point by highlighting the character at whose
;; bounding rectangles left-edge midpoint it is.

;; Bugs:

;; On at least some builds of Emacs version 29.0.50, but not on 28.1, there is
;; a bug where `frame-parameters' are not updated when resizing a frame. This
;; causes the cursor to be wrongly displayed when
;; `edoc-keynav-pointer-as-cursor-minor-mode' is non-nil. A workaround is to run
;; `make-frame' after resizing and closing the old frame.

;; There is a bug in poppler versions 21.03.0-21.07.0 which often causes the
;; alignment between character boundaries and characters to break, which in
;; turn breaks the character-based commands in this minor mode (but not the
;; commands that rely only on the charlayout). In more recent versions of
;; poppler such misalignment is very rare. While `edoc-keynav-charlayout'
;; contains characters in addition to character boundaries, for convenience
;; this code mainly uses `edoc-keynav-text' to access text; both do ultimately
;; rely on `poppler_page_get_text', but the former may be truncated when there
;; is misalignment.

;; The movement commands relating to characters, lines, textregions,
;; paragraphs, and pages rely only on the rectangles in the page charlayout for
;; their functioning, while the movement commands relating to regexes, words,
;; and sentences also require that the charlayout elements are matched to the
;; correct characters.

;; Performance:

;; Since that's how things are currently done in edoc-tools, this minor mode
;; displays the region and cursor by rendering them together with the whole pdf
;; page as one png image which is then displayed in Emacs. This makes things
;; inherently slow.

;; When enabling `edoc-keynav-pointer-as-cursor-minor-mode', the mouse pointer
;; is co-opted to function as a cursor. Like this redrawing the whole page
;; image can be avoided when updating the cursor position, resulting in
;; considerable performance gains.

;; On certain machines with high-resolution displays and `edoc-view-use-scaling'
;; non-nil, the navigation commands provided here may be considerably slower.
;; Other things that negatively influence the performance are
;; `edoc-keynav-transient-mark-mode', `edoc-view-midnight-minor-mode', a high
;; zoom level, and anything else that makes page updates more frequent or more
;; computationally expensive.

;; Keyboard navigation would also be slower if each command were too directly
;; interface with kc and poppler to get the necessary pdf page elements.
;; This is why they are loaded once per page and stored in buffer locals.
;; However, loading these buffer locals at each page change makes scrolling
;; across pages slow, which is why by default they are only loaded for the
;; current page when a command is first used that needs them. See
;; `edoc-keynav-lazy-load'.

;; TODO:

;; Maybe an idle timer for lazy loading of page-specific buffer-locals.

;; Recommended settings outside this minor mode:

;; Set edoc-annot-minor-mode-map-prefix to a single key (like "a" or "m").

;;; Code:

;; * Setup

;; ** Require

(require 'edoc-info)
(require 'edoc-view)
(require 'edoc-util)
(require 'edoc-annot)
(require 'edoc-links)
(require 'edoc-isearch)
(require 'cl-lib)
(require 'dash)
(require 's)


;; ** Custom
(defgroup edoc-keynav nil
  "Keyboard navigation for PDF files."
  :group 'edoc-tools)

(defcustom edoc-keynav-lazy-load t
  "When non-nil load buffer-locals only when first needed on a pdf page.
With nil buffer-locals are loaded directly after a page change, which causes
page scrolling to be slower, while the first edoc-keynav command might feel a
bit quicker."
  :group 'edoc-keynav 
  :type 'boolean)

(defcustom edoc-keynav-start-with-pointer-as-cursor nil
  "When non-nil active pointer-as-cursor with edoc-keynav-minor-mode.
The pointer-as-cursor feature is activated by calling
`edoc-keynav-pointer-as-cursor-minor-mode' whenever `edoc-keynav-minor-mode' is
called."
  :group 'edoc-keynav
  :type 'boolean)

(defcustom edoc-keynav-pointer-hrelpos 0.0
  "Horitzontal positioning of pointer relative to left of character.
Given a charregion (LEFT TOP RIGHT BOT) this controls at what fraction of the
distance between LEFT and RIGHT the cursor is placed. Only relevant in
`edoc-keynav-pointer-as-cursor-minor-mode'."
  :group 'edoc-keynav
  :type 'float)

(defcustom edoc-keynav-pointer-vrelpos 0.1
   "Vertical positioning of pointer relative to bottom of character.
Given a charregion (LEFT TOP RIGHT BOT) this controls at what fraction of the
distance between BOT and TOP the cursor is placed. Only relevant in
`edoc-keynav-pointer-as-cursor-minor-mode'."
  :group 'edoc-keynav
  :type 'float)

(defcustom edoc-keynav-point-from-pointer t
  "When non-nil set point from pointer before running commands.
Only active in `edoc-keynav-pointer-as-cursor-minor-mode'."
  :group 'edoc-keynav
  :type 'boolean)

(defcustom edoc-keynav-pointer-shape 'arrow
  "Shape of the pointer to use when it functions as cursor.
Suitable values include text, arrow, and hand. See the 'Pointer Shape' elisp
manual entry. Only applicable in `edoc-keynav-pointer-as-cursor-minor-mode'."
  :group 'edoc-keynav
  :type 'symbol)

(defcustom edoc-keynav-pointer-layer -4
  "Hotspot layer at which the hotspot for pointer shape is placed.
Hotspots are used in edoc-tools to control, among other things, the shape of the
pointer when hovering over certain image regions. Higher layers take
precedence. Setting the layer to -4, for example, prevents the pointer from
changing shape when hovering over a text region.

By default hotspots for annotations are on layer 9, for links on 0, and for
text on -9. See `edoc-view--hotspot-functions'.

Set to nil to not set any layer and use whatever is default. Only applicable in
`edoc-keynav-pointer-as-cursor-minor-mode'."
  :group 'edoc-keynav
  :type 'integer)

(defcustom edoc-keynav-scroll-window t
  "When non-nil scroll the window so that point is always visible."
  :group 'edoc-keynav
  :type 'boolean)

(defcustom edoc-keynav-scroll-left-margin 10
  "Left margin in pixels between window edge and point after scrolling."
  :group 'edoc-keynav
  :type 'integer)

(defcustom edoc-keynav-scroll-right-margin 25
  "Right margin in pixels between window edge and point after scrolling."
  :group 'edoc-keynav
  :type 'integer)

(defcustom edoc-keynav-no-find-closest-char nil
  "If non-nil mouse selection commands do not search for closest character."
  :group 'edoc-keynav
  :type 'boolean)

(defcustom edoc-keynav-transient-mark-mode nil
  "Non-nil enables `transient-mark-mode'-like region highlighting."
  :group 'edoc-keynav
  :type 'boolean)

(defcustom edoc-keynav-newline-cursor-dimensions '(0.01 . 0.015)
  "Dimensions of the cursor when on a newline character.
Given as (WIDTH . HEIGHT) relative to the page dimensions."
  :type '(cons number number))

(defcustom edoc-keynav-continuous edoc-view-continuous
  "When non-nil, reaching the page edges advances to next/previous page."
  :group 'edoc-keynav
  :type 'boolean)

(defcustom edoc-keynav-paragraph-parameters (list 0.01 0.02 2 5 1 1)
  "List of parameters for determining paragraphs.
Should contain six numeric elements: (dyx-round-to dys-round-to
min-indent max-indent max-dx-discrepancy min-dy-discrepancy)
as described in `edoc-keynav-get-page-paragraphs', to which it is passed."
  :group 'edoc-keynav
  :type '(list number number natnum natnum natnum))

(defcustom edoc-keynav-copy-filter-add-parbreaks t
  "When non-nil add an extra linebreak at paragraph breaks in copied text.
Used by the function `edoc-keynav-copy-filter'."
  :group 'edoc-keynav
  :type 'boolean)

(defcustom edoc-keynav-copy-filter-remove-linebreaks t
  "When non-nil replace single linebreaks with single spaces in copied text.
Used by the function `edoc-keynav-copy-filter'."
  :group 'edoc-keynav
  :type 'boolean)

(defcustom edoc-keynav-copy-region-separator "\n"
  "The separator used between disconnected copied regions of text.
As constructed by `edoc-keynav-mouse-extend-region'."
  :group 'edoc-keynav
  :type 'string)

(defcustom edoc-keynav-copy-region-blink-delay copy-region-blink-delay
  "Number of seconds to highlight copied text.
Highlighting happens when using `edoc-keynav-kill-ring-save',
unless the region is currently displayed. Set 0 to turn off completely."
  :group 'edoc-keynav
  :type 'number)

(defcustom edoc-keynav-select-map-prefix (kbd "e")
  "The prefix to use for `edoc-keynav-select-map'."
  :group 'edoc-keynav
  :type 'string)

(defcustom edoc-keynav-annot-text-margin 10
  "Margin between text annotation and closest text, in pixel.
Used by `edoc-keynav-annot-add-text-left'."
  :group 'edoc-keynav
  :type 'integer)

(defcustom edoc-keynav-sentence-end
  (concat
   ;; (1) Matches non-full-stop sentence ends (with potential footnotes)
   ;; MAYBE should "…" really be a sentence-end character?
   "\\(?:\\([?!…‽][]\"'”’)}»›]*\\)[0-9]*[ \n$]\\)"
   "\\|"
   
   ;; (2) Matches full stop but only when not after certain patterns
   "\\(?:" ;; start group for (2)
   ;; excludes " [A-Z]", " p", "e.g", "i.e", and "et al" before "."
   ;; (other candidates: [1-9], I-X, [a-z], pp, No, Vol/vol, Ed/ed, Eds/eds, etc)
   "\\(?:"
   "\\(?:[^A-Zpgel]\\)" "\\|"
   "\\(?:[^ \n][A-Z]\\)" "\\|"
   "\\(?:[^ \n]p\\)" "\\|"
   "\\(?:[^.][ge]\\)" "\\|"
   "\\(?:[^e][.]g\\)" "\\|"
   "\\(?:[^i][.]e\\)" "\\|"
   "\\(?:[^a]l\\)" "\\|"
   "\\(?:[^ ]al\\)" "\\|"
   "\\(?:[^t] al\\)" "\\|"
   "\\(?:[^e]t al\\)"
   "\\)"
   ;; matches the full stop and what might come after
   ;; [^.] at the end avoids certain dots often used to indicate ranges
   "\\([.][]\"'”’)}»›]*\\)[ \n$][^.]"
   "\\)" ;; end group for (2)
   "\\|"
   
   ;; (3) Matches full stop with footnote but not a decimal
   "\\(?:\\([^0-9][.][]\"'”’)}»›]*\\)[0-9]+[ \n$]\\)")
  "Regexp describing the end of a sentence.
Used by `edoc-keynav-forward-sentence'.

By default '.', '?', '!', '…', and '‽' can end sentences, potentially followed
by closing parentheses, quotation marks, and numerical footnotes, and
necessarily followed by either a space or newline. Dots which follow a single
uppercase letter or 'p', or 'e.g', 'i.e', or 'et al' are ignored.

See the source code for a clearer breakdown of the different parts."
  :group 'edoc-keynav
  :type 'regexp)

(defcustom edoc-keynav-sentence-start
  (concat
   ;; (1) Matches non-full-stop sentence ends (with potential footnotes)
   "\\(?:.\\([ \n]\\)[0-9]*[]\"'”’)}»›]*[?!…‽]\\)"
   "\\|"

   ;; (2) Matches full stop but only when not after certain patterns
   "\\(?:"  ;; start group for (2)
   ;; matches the full stop and what might come after
   "[^.]\\([ \n]\\)[]\"'”’)}»›]*[.]"
   ;; excludes " [A-Z]", " p", "e.g", "i.e", and "et al" before "."
   "\\(?:"
   "\\(?:[^A-Zpgel]\\)" "\\|"
   "\\(?:[A-Z][^ \n]\\)" "\\|"
   "\\(?:p[^ \n]\\)" "\\|"
   "\\(?:[ge][^.]\\)" "\\|"
   "\\(?:g[.][^e]\\)" "\\|"
   "\\(?:e[.][^i]\\)" "\\|"
   "\\(?:l[^a]\\)" "\\|"
   "\\(?:la[^ ]\\)" "\\|"
   "\\(?:la [^t]\\)" "\\|"
   "\\(?:la t[^e]\\)"
   "\\)"
   "\\)"  ;; end group for (2)
   "\\|"
   
   ;; (3) Matches full stop with footnote but not a decimal
   "\\(?:.\\([ \n][0-9]+\\)[]\"'”’)}»›]*[.][^0-9]\\)")
  "Regexp describing the start of a sentence.
Used by `edoc-keynav-backward-sentence'.

This is the reverse of `edoc-keynav-sentence-end' used for forward-matching on
the reversed string.

See the source code for a clearer breakdown of the different parts."
  :group 'edoc-keynav
  :type 'regexp)



;; ** Buffer-locals

(defvar-local edoc-keynav-page nil
  "Keeps track of last pdf page for which buffer-locals were set.")

(defvar-local edoc-keynav-charlayout nil
  "List of characters on current page with their bounding rectangles.

Each element is of the form (CHAR (LEFT TOP RIGHT BOT)).

CHAR is a character (represented by an integer in elisp; (string CHAR) gives
its string representation).

LEFT, TOP, RIGHT, and BOT are relative coordinates in a coordinate system with
the origin at the top left corner of the pdf page, the x-axis horizontally to
the right, and the y-axis vertically down:

LEFT is the x-coordinate of the left edge of the bounding rectangle,
TOP is the y-coordinate of its top edge,
RIGHT is the x-coordinate of the right edge,
BOT is the y-coordinate of its bottom edge.

Expressed differently, (LEFT TOP RIGHT BOT) = (X1 Y1 X2 Y2), where (X1, Y1) are
the coordinates of the left-top vertex of the characters bounding rectangle and
(X2, Y2) are the coordinates of the right-bottom vertex.

Each x-coordinate is expressed as a fraction of (that is, relative to) the
total page width and each y-coordinate as a fraction of to the total page
height.

This variable is the basis of most commands in edoc-keynav. It is constructed by
calling `edoc-info-charlayout' which in turn calls the C command
`cmd_charlayout' defined in kc.c. `cmd_charlayout' just combines the
characters returned by `poppler_page_get_text' with the charregions returned by
`poppler_page_get_text_layout', both of which are part of the glib frontend/API
of poppler (see the poppler glib documentation).

In poppler, characters bounding boxes (charregions) normally have the same
height within a line (that is TOP and BOT are the same), but their widths
differ.")

(defvar-local edoc-keynav-point nil
  "Index in `edoc-keynav-charlayout' of the character at point.")

(defvar-local edoc-keynav-mark nil
  "Index in `edoc-keynav-charlayout' of the character at mark.")

(defvar-local edoc-keynav-text nil
  "String holding all the text on current page.")

(defvar-local edoc-keynav-textregions nil
  "List of lists of relative coordinates of textregions on current page.
Each element is of the form (LEFT TOP RIGHT BOT), see
`edoc-keynav-charlayout'.

For more about textregions see `edoc-keynav-textregion-at-point'.")

(defvar-local edoc-keynav-linestarts nil
  "List of indices indicating where each line on current page starts.
The indices indicate positions in `edoc-keynav-charlayout'.")

(defvar-local edoc-keynav-lineends nil
  "List of indices indicating where each line on current page ends.
The indices indicate positions in `edoc-keynav-charlayout'.")

(defvar-local edoc-keynav-parstarts nil
  "List of indices indicating where each paragraph on current page starts.
The indices indicate positions in `edoc-keynav-charlayout'.")
  
(defvar-local edoc-keynav-parends nil
  "List of indices indicating where each paragraph on current page ends.
The indices indicate positions in `edoc-keynav-charlayout'.")

(defvar-local edoc-keynav-temporary-goal-column 0
  "Relative x-coordinate indicating the goal 'column' for the point.
Used when moving between lines with `edoc-keynav-next-line' and
`edoc-keynav-previous-line'.")

(defvar-local edoc-keynav-mark-active-p nil
  "Non-nil if the mark is active.")


(defun edoc-keynav-setup-buffer-locals ()
  "Set the values of page-specific variables used for page navigation.

Set `edoc-keynav-page' to the current page, set `edoc-keynav-point' and
`edoc-keynav-mark' to zero, load `edoc-keynav-charlayout', `edoc-keynav-text',
and `edoc-keynav-textregions' via kc.c and poppler, plus determine
`edoc-keynav-lineends', `edoc-keynav-linestarts', `edoc-keynav-parstarts', and
`edoc-keynav-parends'.

The variable and function `edoc-keynav-lazy-load' control when this function
is run."
  ;; MAYBE write with just one setq
  (setq edoc-keynav-page (edoc-view-current-page))
  (setq edoc-keynav-point 0)
  (setq edoc-keynav-mark 0)
  (setq edoc-keynav-charlayout
	;; add a linebreak as the last charlayout element on page
	(let* ((charlayoutin (edoc-info-charlayout
			      (edoc-view-current-page) nil nil))
	       (finaledgesin (if charlayoutin
                                 (nth 1 (-last-item charlayoutin))
                               (cons (string-to-char "\n")
                                     (list 0.1 0.1 0.1 0.1))))
	       (finaledgesout (list (nth 2 finaledgesin)
				    (nth 3 finaledgesin)
				    (nth 2 finaledgesin)
				    (nth 3 finaledgesin)))
	       (newfinalelement (cons (string-to-char "\n")
				      (list finaledgesout))))
	  (-concat charlayoutin (list newfinalelement))))
  (setq edoc-keynav-text
	;; add a linebreak at end like in edoc-keynav-charlayout
	(concat
	 (edoc-info-gettext
	  (edoc-view-current-page) '(0 0 1 1))
	 "\n"))
  (setq edoc-keynav-textregions
	(edoc-info-textregions
	 (edoc-view-current-page) nil))
  (setq edoc-keynav-lineends
	;; this is more robust than just checking index of "\n"
        (if edoc-keynav-charlayout
	    (--find-indices
	     (let* ((edges (nth 1 it))
		    (x1 (nth 0 edges))
		    (y1 (nth 1 edges))
		    (x2 (nth 2 edges))
		    (y2 (nth 3 edges))
		    (width (- x2 x1))
		    (height (- y2 y1))
		    (roundto 0.000000001))
	       (and
	        (equal (round width roundto) 0)
	        (equal (round height roundto) 0)))
	     edoc-keynav-charlayout)
          '(0)))
  (setq edoc-keynav-linestarts
	(-concat '(0)
		 (-map #'1+ (butlast edoc-keynav-lineends))))
  (setq edoc-keynav-parstarts
	(apply 'edoc-keynav-get-page-paragraphs
	       edoc-keynav-paragraph-parameters))
  (setq edoc-keynav-parends
	(-concat (--map (1- it)  (cdr edoc-keynav-parstarts))
		 (list (1- (length edoc-keynav-charlayout))))))


(defun edoc-keynav-lazy-load ()
  "Load buffer-locals if they have not been loaded yet for the current page.
Buffer-local `edoc-keynav-page' keeps track of the last page for which the
necessary buffer-locals have been loaded."
  (unless (equal edoc-keynav-page (edoc-view-current-page))
    (edoc-keynav-setup-buffer-locals)))

(defvar edoc-keynav-make-pointer-invisible-original-value make-pointer-invisible
  "Value of `make-pointer-invisible' before display-pointer-as-cursor.")


;; ** Minor mode

(defvar edoc-keynav-minor-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Navigate
    (define-key map [remap forward-char] 'edoc-keynav-forward-char)
    (define-key map [remap backward-char] 'edoc-keynav-backward-char)
    (define-key map [remap forward-word] 'edoc-keynav-forward-word)
    (define-key map [remap backward-word] 'edoc-keynav-backward-word)
    (define-key map [remap next-line] 'edoc-keynav-next-line)
    (define-key map [remap previous-line] 'edoc-keynav-previous-line)
    (define-key map (kbd "C-M-s-n") 'edoc-keynav-forward-line)
    (define-key map (kbd "C-M-s-p") 'edoc-keynav-backward-line)
    (define-key map [remap move-beginning-of-line] 'edoc-keynav-beginning-of-line)
    (define-key map [remap move-end-of-line] 'edoc-keynav-end-of-line)
    (define-key map (kbd "C-m") 'edoc-keynav-middle-of-line)
    (define-key map (kbd "C-s-n") 'edoc-keynav-forward-textregion)
    (define-key map (kbd "C-s-p") 'edoc-keynav-backward-textregion)
    (define-key map (kbd "C-s-a") 'edoc-keynav-beginning-of-textregion)
    (define-key map (kbd "C-s-e") 'edoc-keynav-end-of-textregion)
    (define-key map [remap forward-sentence] 'edoc-keynav-forward-sentence)
    (define-key map [remap backward-sentence] 'edoc-keynav-backward-sentence)
    (define-key map (kbd "C-M-n") 'edoc-keynav-forward-paragraph)
    (define-key map [remap forward-paragraph] 'edoc-keynav-forward-paragraph)
    (define-key map (kbd "C-M-p") 'edoc-keynav-backward-paragraph)
    (define-key map [remap backward-paragraph] 'edoc-keynav-backward-paragraph)
    (define-key map (kbd "C-M-a") 'edoc-keynav-beginning-of-paragraph)
    (define-key map (kbd "C-M-e") 'edoc-keynav-end-of-paragraph)
    (define-key map (kbd "C-M-m") 'edoc-keynav-middle-of-paragraph)
    (define-key map (kbd "<") 'edoc-keynav-beginning-of-page)
    (define-key map (kbd ">") 'edoc-keynav-end-of-page)
    (define-key map (kbd "C-<") 'edoc-keynav-middle-of-page)
    ;; Mark
    (define-key map [remap set-mark-command] 'edoc-keynav-set-mark-command)
    (define-key map [remap exchange-point-and-mark] 'edoc-keynav-exchange-point-and-mark)
    (define-key map [remap keyboard-quit] 'edoc-keynav-keyboard-quit)
    ;; Select
    (let ((smap (make-sparse-keymap)))
      (define-key map edoc-keynav-select-map-prefix smap)
      (define-key smap "1" 'edoc-keynav-select-word)
      (define-key smap "2" 'edoc-keynav-select-line)
      (define-key smap "3" 'edoc-keynav-select-sentence)
      (define-key smap "4" 'edoc-keynav-select-paragraph))
    (define-key map [remap mark-whole-buffer] 'edoc-keynav-select-page)
    ;; Select using mouse
    (define-key map [double-mouse-1] 'edoc-keynav-mouse-select-word)
    (define-key map [triple-mouse-1] 'edoc-keynav-mouse-select-sentence)
    (define-key map [S-mouse-1] 'edoc-keynav-mouse-select-sentence)
    (define-key map [S-double-mouse-1] 'edoc-keynav-mouse-select-paragraph)
    (define-key map [down-mouse-1] 'edoc-keynav-mouse-set-region)
    (define-key map [C-down-mouse-1] 'edoc-keynav-mouse-extend-region)
    ;; Copy
    (define-key map [remap kill-ring-save] 'edoc-keynav-kill-ring-save)
    (define-key map [remap ns-copy-including-secondary] 'edoc-keynav-kill-ring-save)
    ;; Annotate
    (define-key map [return] 'edoc-keynav-annot-activate)
    (define-key map [C-backspace] 'edoc-keynav-annot-delete)
    map)
  "Keymap for `edoc-keynav-minor-mode-map'.")


;;;###autoload
(define-minor-mode edoc-keynav-minor-mode
  "Enables keyboard navigation of PDFView buffers.

\\{edoc-keynav-minor-mode-map}."
  :keymap edoc-keynav-minor-mode-map

  (if edoc-keynav-minor-mode

      (progn
	(message "Activating edoc-keynav-minor-mode")
	(setq edoc-keynav--cursor-in-flight nil
	      edoc-keynav--cursor-pending nil
	      edoc-keynav--cursor-shown nil)
	(unless edoc-keynav-lazy-load
	  (edoc-keynav-setup-buffer-locals)
	  (add-hook 'edoc-view-after-change-page-hook
		    #'edoc-keynav-setup-buffer-locals nil 'local))
                
	;; isearch compatibility
	(add-hook 'isearch-mode-end-hook
		  #'edoc-keynav-isearch-mode-end-set-point 10 'local)
	(add-hook 'isearch-mode-hook
		  #'edoc-keynav-isearch-invalidate-cursor nil 'local)
	(setq edoc-isearch-filter-matches-function
	      'edoc-keynav-isearch-filter-matches)

	;; edoc-occur compatibility
	(with-eval-after-load 'edoc-occur
	  (define-key edoc-occur-buffer-mode-map
		      [remap edoc-occur-goto-occurrence]
		      'edoc-keynav-occur-goto-occurence))

	;; edoc-annot compatibility
	(advice-add 'edoc-view-active-region :before
		    #'edoc-keynav-region-to-active-region)
	(advice-add 'edoc-annot-add-markup-annotation :after
		    #'edoc-keynav-after-markup-advice)
        (advice-add 'edoc-annot-edit-contents-finalize :after
	            #'edoc-keynav-after-markup-advice)

        ;; add some bindings to edoc-annot-minor-mode-map
        (define-key edoc-annot-minor-mode-map
          (kbd (concat edoc-annot-minor-mode-map-prefix " <left>"))
          'edoc-keynav-annot-add-text-left)
        (define-key edoc-annot-minor-mode-map
          (kbd (concat edoc-annot-minor-mode-map-prefix " <right>"))
          'edoc-keynav-annot-add-text-right)
	
	;; remove conflicting keybindings
	(let ((map edoc-view-mode-map))
	  (define-key map (kbd "C-n") nil)
	  (define-key map [remap next-line] nil)
	  (define-key map (kbd "C-p") nil)
	  (define-key map [remap previous-line] nil)
	  ;; MAYBE remove remapping of r and m or do it in edoc-view
	  ;; free up m for "markup", revert-buffer is also bound to g
	  (define-key map (kbd "r") 'edoc-view-position-to-register)
	  (define-key map (kbd "m") nil))
	(with-eval-after-load 'edoc-sync
	  (define-key edoc-sync-minor-mode-map [double-mouse-1] nil))

        ;; display pointer as cursor
        (when edoc-keynav-start-with-pointer-as-cursor          
          (edoc-keynav-setup-buffer-locals) ;; FIXME fails sometimes
          (edoc-keynav-pointer-as-cursor-minor-mode 1)))

    
    (message "Deactivating edoc-keynav-minor-mode")
    (remove-hook 'edoc-view-after-change-page-hook
                 #'edoc-keynav-setup-buffer-locals 'local)

    ;; isearch compatibility
    (remove-hook 'isearch-mode-end-hook
		 #'edoc-keynav-isearch-mode-end-set-point 'local)
    (remove-hook 'isearch-mode-hook
		 #'edoc-keynav-isearch-invalidate-cursor 'local)
    (setq edoc-isearch-filter-matches-function nil)

    ;; edoc-occur compatibility
    (let ((map edoc-occur-buffer-mode-map))
      (define-key map [remap edoc-occur-goto-occurrence]	nil))

    ;; edoc-annot compatibility
    (advice-remove 'edoc-view-active-region
		   #'edoc-keynav-region-to-active-region)
    (advice-remove 'edoc-annot-add-markup-annotation
		   #'edoc-keynav-after-markup-advice)
    (advice-remove 'edoc-annot-edit-contents-finalize
	           #'edoc-keynav-after-markup-advice)

    ;; remove bindings to edoc-annot-minor-mode-map
    (define-key edoc-annot-minor-mode-map
      (kbd (concat edoc-annot-minor-mode-map-prefix " <left>"))
      nil)
    (define-key edoc-annot-minor-mode-map
      (kbd (concat edoc-annot-minor-mode-map-prefix " <right>"))
      nil)


    ;; add back previously removed keybindings
    (let ((map edoc-view-mode-map))
      (define-key map (kbd "C-n") 'edoc-view-next-line-or-next-page)
      (define-key map [remap next-line] 'edoc-view-next-line-or-next-page)
      (define-key map (kbd "C-p") 'edoc-view-previous-line-or-previous-page)
      (define-key map [remap previous-line]
	'edoc-view-previous-line-or-previous-page)
      (define-key map (kbd "r") 'revert-buffer)
      (define-key map (kbd "m") 'edoc-view-position-to-register))
    (when (boundp 'edoc-sync-minor-mode-map)
      (define-key edoc-sync-minor-mode-map [double-mouse-1] 'edoc-sync-backward-search-mouse))

    ;; disable displaying pointer as cursor
    (edoc-keynav-pointer-as-cursor-minor-mode 0)
    
    ;; redisplay to remove region/point
    (edoc-view-redisplay)))


(define-minor-mode edoc-keynav-pointer-as-cursor-minor-mode
  "Co-opt the mouse pointer to act as cursor."
  :init-value nil
  
  (if (bound-and-true-p edoc-keynav-pointer-as-cursor-minor-mode)
      
      (progn
        (message "Activating edoc-keynav-pointer-as-cursor-minor-mode")
        
        ;; don't hide pointer
        (setq edoc-keynav-make-pointer-invisible-original-value
              make-pointer-invisible)
        (setq make-pointer-invisible nil)

        ;; add hotspot to control pointer shape
        (when edoc-keynav-pointer-layer 
          (edoc-view-add-hotspot-function
           'edoc-keynav-hotspot-function edoc-keynav-pointer-layer))

        ;; remove unnecessary advice
        (advice-remove 'edoc-annot-edit-contents-finalize
	               #'edoc-keynav-after-markup-advice)

        ;; pointer behavior in isearch
        (advice-add 'edoc-isearch-focus-match :after
	    'pdv-keynav-isearch-focus-match-advice)
        (add-hook 'isearch-mode-hook 'edoc-keynav-isearch-mode-hook)
        
        (edoc-view-redisplay))
    
    (message "Deactivating edoc-keynav-pointer-as-cursor-minor-mode")

    ;; reset pointer hiding behavior
    (setq make-pointer-invisible
          edoc-keynav-make-pointer-invisible-original-value)
    
    ;; stop controlling pointer shape
    (edoc-view-remove-hotspot-function
     'edoc-keynav-hotspot-function)

    ;; add back advice
    (advice-add 'edoc-annot-edit-contents-finalize :after
	        #'edoc-keynav-after-markup-advice)

    ;; restore old isearch behavior
    (advice-remove 'edoc-isearch-focus-match
	           'pdv-keynav-isearch-focus-match-advice)
    (remove-hook 'isearch-mode-hook 'edoc-keynav-isearch-mode-hook))
    
  (edoc-keynav-display-region-cursor))


;; * Display

(defun edoc-keynav-display-region-cursor ()
  "Display either the region between mark and point or the cursor at point.
If variables `edoc-keynav-transient-mark-mode' and `edoc-keynav-mark-active-p'
are non-nil, and mark is not exactly at point, display the region;
else display the cursor at point.

This function should be called whenever the display of the region/cursor has to
be updated, for example after point has been moved.

Mark and point are indices of `edoc-keynav-charlayout' given by
`edoc-keynav-mark' and `edoc-keynav-point'. The region is the area of the
(bounding rectangles of the) characters between mark and point. It is displayed
by highlighting it using `edoc-view-display-region'. The cursor is displayed by
highlighting the bounding rectangle of the character at point using
`edoc-keynav-display-cursor'.

Character bounding rectangles corresponding to newline characters have zero
width and height. In order to make these visible when point is on them they are
inflated in size according to `edoc-keynav-newline-cursor-dimensions'.

If the variable `edoc-keynav-scroll-window' is non-nil, scroll window so that
point is visible."
  ;; MAYBE Can this be made faster?
  ;;       e.g. by overlaying only a small image to display region/cursor?
 ;; MAYBE Display region and cursor at the same time in different styles? 
  ;;       just pass right args to edoc-info-renderpage-text-regions
  ;; cursor is only displayed when region isn't displayed
  (when edoc-keynav-scroll-window
    (edoc-keynav-scroll-to-edges))  
  (if (and edoc-keynav-transient-mark-mode
	   edoc-keynav-mark-active-p
	   (not (equal edoc-keynav-point edoc-keynav-mark)))
      ;; display region
      (edoc-view-display-region
       (list (edoc-keynav-get-region-rpos)))
    ;; else display cursor
    (let ((inrectangle
	   (nth 1 (nth edoc-keynav-point edoc-keynav-charlayout)))
	  (cursor-dim
	   edoc-keynav-newline-cursor-dimensions))
      (if edoc-keynav-pointer-as-cursor-minor-mode
          (edoc-keynav-display-pointer-as-cursor
           (list inrectangle))
        (if (-contains? edoc-keynav-lineends edoc-keynav-point)
	  ;; at newline characters cursor is displayed as inflated rectangle
	  (edoc-keynav-display-cursor
	   ;; MAYBE base newline rectangle on previous charregion/line instead
	   ;; MAYBE display newline rectangle in the same style as usual
	   (list (--update-at
		  1 (- it (cdr cursor-dim))
		  (--update-at
		   2 (+ it (car cursor-dim)) inrectangle)))
	   t)
	;; else cursor is displayed by highlighting the bounding rectangle
	(edoc-keynav-display-cursor
	 (list inrectangle)))))))

(defvar-local edoc-keynav--cursor-tick 0
  "Generation counter for asynchronous cursor rendering.")

(defvar-local edoc-keynav--cursor-in-flight nil
  "Non-nil while a cursor render request is waiting for the server.")

(defvar-local edoc-keynav--cursor-pending nil
  "The latest cursor render request, coalescing keys pressed in quick succession.")

(defvar-local edoc-keynav--cursor-shown nil
  "The request whose image is currently displayed as the cursor.")

(defun edoc-keynav-isearch-invalidate-cursor ()
  "Forget the displayed cursor while isearch owns the page image."
  (cl-incf edoc-keynav--cursor-tick)
  (setq edoc-keynav--cursor-pending nil
        edoc-keynav--cursor-shown nil))

(defun edoc-keynav-display-cursor (region
				  &optional rectangle-p not-single-line-p)
  "Modification of `edoc-view-display-region' used to display the cursor.
REGION is a list of lists of edges in page-relative coordinates,
like ((X1 Y1 X2 Y2)).

The color of the cursor is set as `edoc-view-midnight-colors'. RECTANGLE-P
displays in style of a rectangle. NOT-SINGLE-LINE-P doesn't limit the displayed
region to one line.

Rendering is asynchronous and coalesced: moving point never waits for the
server, and at most one request is in flight.  A response is only displayed if
point, page and image width are still the ones it was computed for."
  (when (and edoc-keynav-minor-mode
             (not (bound-and-true-p isearch-mode)))
    (let* ((colors (if (and (not (bound-and-true-p edoc-view-midnight-minor-mode))
                            (eq 'dark (frame-parameter nil 'background-mode)))
                       edoc-view-midnight-colors
                     (cons (cdr edoc-view-midnight-colors)
                           (car edoc-view-midnight-colors))))
           (page (edoc-view-current-page))
           (width (car (edoc-view-image-size)))
           (single-line-p (unless not-single-line-p t))
           (key (list page width region rectangle-p single-line-p colors)))
      (unless (equal key edoc-keynav--cursor-shown)
        (cl-incf edoc-keynav--cursor-tick)
        (setq edoc-keynav--cursor-pending
              (list :tick edoc-keynav--cursor-tick
                    :key key
                    :buffer (current-buffer)
                    :window (selected-window)
                    :page page
                    :width width
                    :colors colors
                    :region region
                    :rectangle-p rectangle-p
                    :single-line-p single-line-p))
        (edoc-keynav--pump-cursor-render)))))

(defun edoc-keynav--pump-cursor-render ()
  "Send the latest pending cursor render request, unless one is in flight."
  (when (and (not edoc-keynav--cursor-in-flight)
             edoc-keynav--cursor-pending)
    (let* ((request edoc-keynav--cursor-pending)
           (buffer (plist-get request :buffer))
           (window (plist-get request :window))
           (tick (plist-get request :tick))
           (page (plist-get request :page))
           (width (plist-get request :width))
           (colors (plist-get request :colors))
           (region (plist-get request :region))
           (rectangle-p (plist-get request :rectangle-p))
           (single-line-p (plist-get request :single-line-p)))
      (setq edoc-keynav--cursor-pending nil)
      (if (not (and (buffer-live-p buffer) (window-live-p window)))
          (edoc-keynav--pump-cursor-render)
        (setq edoc-keynav--cursor-in-flight t)
        (let ((edoc-info-asynchronous
               (lambda (status data)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (setq edoc-keynav--cursor-in-flight nil)
                     (condition-case err
                         (when (and (null status)
                                    (= tick edoc-keynav--cursor-tick)
                                    (not (bound-and-true-p isearch-mode))
                                    (window-live-p window)
                                    (eq (window-buffer window) buffer))
                           (with-selected-window window
                             (when (and (derived-mode-p 'edoc-view-mode)
                                        edoc-keynav-minor-mode
                                        (= page (edoc-view-current-page window))
                                        (= width (car (edoc-view-image-size nil window))))
                               (edoc-view-display-image
                                (edoc-view-create-image data :width width))
                               (setq edoc-keynav--cursor-shown
                                     (plist-get request :key)))))
                       (error
                        (message "edoc-keynav cursor display failed: %s"
                                 (error-message-string err))))
                     (edoc-keynav--pump-cursor-render))))))
          (condition-case err
              (with-current-buffer buffer
                (if rectangle-p
                    (edoc-info-renderpage-highlight
                     page width nil
                     `(,(car colors) ,(cdr colors) 0.35 ,@region))
                  (edoc-info-renderpage-text-regions
                   page width single-line-p nil
                   `(,(car colors) ,(cdr colors) ,@region))))
            (error
             (setq edoc-keynav--cursor-in-flight nil)
             (message "edoc-keynav cursor render failed: %s"
                      (error-message-string err)))))))))

(defun edoc-keynav-display-pointer-as-cursor (region &optional rectangle-p
                                                    not-single-line-p)
  "Sets the position of the mouse pointer based on REGION.
REGION will usually be the charregion of the character at point.

This function is used to co-opt the pointer as a cursor when
`edoc-keynav-pointer-as-cursor-minor-mode` is non-nil.

REGION should be a rectangle given as (LEFT TOP RIGHT BOT).
`edoc-keynav-pointer-hrelpos` controls at what fraction of the distance between
LEFT and RIGHT the cursor is placed, while `edoc-keynav-pointer-vrelpos` does
the same for BOT and TOP. If both are zero the cursor will be placed at (LEFT,
BOT).

The core of this function is `set-mouse-pixel-position`, which takes left and
top coordinates in pixels relative to the frame's outer edges. In edoc-keynav
coordinates are normally relative to the image of a pdf page. This image in
turn might be smaller or larger than the window it is in. In addition, a window
is smaller than a frame. An attempt is made to consider all this. Still, if the
image is narrower than the window, positioning is inexact."
  ;; FIXME does this still introduce new bugs?
  ;; MAYBE Can't get more exact positioning, but someone may be able to?
  (let* ((outer-edges (frame-edges (selected-frame) 'outer-edges))
         (inner-edges-abs (window-edges nil nil t t))
         (inner-edges-rel (window-edges nil nil nil t))
         (window-left-offset (- (nth 0 inner-edges-abs)
                                (nth 0 outer-edges)))
         (window-top-offset (nth 1 inner-edges-rel))
         (char-region (edoc-util-scale-relative-to-pixel
                       (nth 0 region)))
         (image-displayed-edges (edoc-util-image-displayed-edges))
         (image-width (car (edoc-view-image-size)))
         (image-left-offset (/ (- (window-pixel-width)
                                  image-width)
                               2))
         ;; assumes the image is horizontally centered
         ;; this is not exact, due to rounding, but using the inverse
         ;; of edoc-view-center-in-window is not better
         ;; it is assumed that image-top-offset is always 0
         (xpos ;; relative to left top corner of window
          (round
           (- (+ (* (- 1.0 edoc-keynav-pointer-hrelpos)
                    (nth 0 char-region))
                 (* edoc-keynav-pointer-hrelpos
                    (nth 2 char-region)))
              (nth 0 image-displayed-edges))))

         (ypos ;; relative to left top corner of window
          (round 
           (- (+ (* (- 1.0 edoc-keynav-pointer-vrelpos)
                    (nth 3 char-region))
                 (* edoc-keynav-pointer-vrelpos
                    (nth 1 char-region)))
              (nth 1 image-displayed-edges)))))
    ;; HACK pointer seems to behave less erratic when message is called
    ;;       even a nil message works
    ;; (message "xpos: %s  ypos: %s" xpos ypos)
    (message nil)
    (set-mouse-pixel-position
     (selected-frame)
     (+ xpos (max 0 image-left-offset) window-left-offset)
     (+ ypos window-top-offset))))

(defun edoc-keynav-scroll-to-edges (&optional eager-p)
  "Scroll window so that point is visible; wraps `edoc-util-scroll-to-edges'.
Variables `edoc-keynav-scroll-left-margin' and `edoc-keynav-scroll-right-margin'
control the size of the horizontal margins after scrolling.

Variable `next-screen-context-lines' controls the size of the vertical margins
after scrolling."
  ;; NOTE: The context-pixel argument partly does this,
  ;;       but using it left and right scroll margin have to be the same,
  ;;       which is not nice since newline characters are displayed only on
  ;;       the right margin.
  ;; MAYBE specify margins relative and translate before relative-to-pixel?
  (let* ((edges-in (edoc-util-scale-relative-to-pixel
		    (nth 1 (nth edoc-keynav-point
				edoc-keynav-charlayout))))
	 (edges-tmp (--update-at 0
				 (max 0
				      (- it edoc-keynav-scroll-left-margin))
				 edges-in))
	 (edges-out (--update-at 2
				 (min (cdr (edoc-view-image-size))
				      (+ it edoc-keynav-scroll-right-margin))
				 edges-tmp)))
    (edoc-util-scroll-to-edges edges-out eager-p)))


(defun edoc-keynav-toggle-point-from-pointer ()
  "Toggles `edoc-keynav-point-from-pointer'.
When this variable is non-nil, point follows the mouse pointer also when it is
moved using the mouse/trackpad. Point will simple be where the pointer is, in
almost all settings. Only active when `edoc-keynav-pointer-as-cursor-minor-mode'."
  (interactive)
  (setq edoc-keynav-point-from-pointer
        (not edoc-keynav-point-from-pointer)))


(defun edoc-keynav-hotspot-function (page size)
  "Create image hotspot covering the whole image to control pointer shape."
  (local-set-key [edoc-view-text-region t]
                 'edoc-util-image-map-mouse-event-proxy)
  (list `((rect . ((0 . 0) . (,(car size) . ,(cdr size))))
	  edoc-view-text-region
	  (pointer ,edoc-keynav-pointer-shape))))


;; * Navigate

;; ** Characters

(defun edoc-keynav-forward-char (&optional n)
  "Move point to next character and display region/cursor.
With argument N move n characters forward.

If `edoc-keynav-continuous' is non-nil move across page breaks (moving at most
one character into the adjacent page, truncating N)."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (if (> (+ edoc-keynav-point n)
	 (1- (length edoc-keynav-charlayout)))
      (if edoc-keynav-continuous
	  (let ((edoc-view-inhibit-redisplay
                 (not edoc-keynav-pointer-as-cursor-minor-mode)))
	    (edoc-view-next-page)
	    (if edoc-keynav-lazy-load
		(edoc-keynav-setup-buffer-locals)))
	(setq edoc-keynav-point
	      (1- (length edoc-keynav-charlayout))))
    (setq edoc-keynav-point
	  (+ edoc-keynav-point n)))
  (edoc-keynav-display-region-cursor))


(defun edoc-keynav-backward-char (&optional n)
  "Move point to previous character and display region/cursor.
With argument N move n characters backwards.

If `edoc-keynav-continuous' is non-nil move across page breaks (moving at most
one character into the adjacent page, truncating N)."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (if (< (- edoc-keynav-point n) 0)
      (if edoc-keynav-continuous
	  (let ((edoc-view-inhibit-redisplay
                 (not edoc-keynav-pointer-as-cursor-minor-mode)))
	    (edoc-view-previous-page)
	    (if edoc-keynav-lazy-load
		(edoc-keynav-setup-buffer-locals))
	    (edoc-keynav-end-of-page t)
	    (setq edoc-keynav-mark edoc-keynav-point))
	(setq edoc-keynav-point 0))
    (setq edoc-keynav-point
	  (- edoc-keynav-point n)))
  (edoc-keynav-display-region-cursor))



;; ** Regexes

(defun edoc-keynav-forward-regex (regex)
  "Search page forwards for REGEX.
Also set point at match-start and display region/cursor."
  (interactive "sregex: ")
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (setq edoc-keynav-point
	(string-match
	 regex
	 edoc-keynav-text
	 edoc-keynav-point))
  (edoc-keynav-display-region-cursor))


(defun edoc-keynav-backward-regex (regex)
  "Search page backwards for REGEX.
Also set point at match-start and display region/cursor."
  (interactive "sregex: ")
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (setq edoc-keynav-point
	(car
	 (-last-item
	  (s-matched-positions-all
	   regex
	   (substring edoc-keynav-text
		      0
		      edoc-keynav-point)))))
  (edoc-keynav-display-region-cursor))


(defun edoc-keynav-isearch-filter-matches (matches)
  "Filters matches in isearch to return only those after or before point.
When using `isearch-forward' only matches below point or at the same height but
to the right of point are returned. When using `isearch-backward' only matches
above point or at the same height but to the left of point are returned. Needs
to be set to `edoc-isearch-filter-matches-function' to have an effect."
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (let ((point (edoc-keynav-point-to-pixel-pos t)))
    (if isearch-forward
	(if (equal edoc-keynav-point 0) ;; avoids filtering after jumping pages
	    matches
	  (--filter
	   (or
	    ;; below
	    (> (nth 1 (car it))
	       (1+ (cdr point)))
	    ;; or same row and to the right
	    (and
	     (> (nth 1 (car it))
		(1- (cdr point)))
	     (> (nth 0 (car it))
		(1+ (car point)))))
	   matches))
      ;; case when isearch-backward
      (if (equal edoc-keynav-point 0) ;; avoids filtering after jumping pages
	  matches
	(--filter
	 (or
	  ;; above
	  (< (nth 1 (car it))
	     (1- (cdr point)))
	  ;; or same row and to the left
	  (and
	   (< (nth 1 (car it))
	      (1+ (cdr point)))
	   (< (nth 0 (car it))
	      (1- (car point)))
	   ))
	 matches)))))


(defun edoc-keynav-isearch-mode-end-set-point ()
  "Set point to position of `edoc-isearch-current-match' and displays cursor.
If the user quits isearch, then just display cursor. This function is bound to
`isearch-mode-end-hook' so that it is run whenever isearch-mode ends."
  ;; FIXME want to both display cursor on quit and go back to starting point
  ;;       even across pages
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (let ((edges (car edoc-isearch-current-match)))
    (if isearch-mode-end-hook-quit
	(edoc-keynav-display-region-cursor)
      (setq edoc-keynav-point
 	    (edoc-keynav-pixel-pos-to-ichar
	     ;; tries to prevent rounding/overlap issues
	     ;; by picking an interior point
	     (cons (1+ (nth 0 edges))
		   (/ (+ (nth 1 edges)
			 (nth 3 edges))
		      2)))))
    (edoc-keynav-display-region-cursor)))


(defun pdv-keynav-isearch-focus-match-advice (&rest region)
  "Moves the pointer to current match.
Only active in `edoc-keynav-pointer-as-cursor-minor-mode'."
  (when edoc-keynav-pointer-as-cursor-minor-mode
    (edoc-keynav-display-pointer-as-cursor
     (edoc-util-scale-pixel-to-relative (nth 0 region)))))


(defun edoc-keynav-isearch-mode-hook ()
  "Set point from pointer before running isearch.
Only active in `edoc-keynav-pointer-as-cursor-minor-mode'."  
  (when (and edoc-keynav-pointer-as-cursor-minor-mode
             edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer)))


(defun edoc-keynav-occur-goto-occurence ()
  "Go to the occurrence at point.

Modification of `edoc-occur-goto-occurrence' that sets point and displays cursor
at beginning of match."
  (interactive)
  (let ((item (tabulated-list-get-id)))
    (when item
      (let* ((doc (plist-get item :document))
             (page (plist-get item :page))
             (match (plist-get item :match-edges))
             (buffer (if (bufferp doc)
                         doc
                       (or (find-buffer-visiting doc)
                           (find-file-noselect doc))))
             window)
	(pop-to-buffer buffer)
	(setq window (selected-window))
        (with-selected-window window
          (when page
            (edoc-view-goto-page page))
          (when match
            (let ((edges (nth 0 match)))
	      (if edoc-keynav-lazy-load
		  (edoc-keynav-lazy-load))
	      (setq edoc-keynav-point
		    (edoc-keynav-relative-pos-to-ichar
		     (cons (nth 0 edges)
			   (/ (+ (nth 1 edges)
				 (nth 3 edges))
			      2))))
	      (edoc-keynav-display-region-cursor))))))))



;; ** Words

(defun edoc-keynav-forward-word (&optional n nodisplay)
  "Move point forward N words and display region/cursor.
Move point to end of current word. If point is at end of a word or at
whitespace, move to end of next word.

Do not display region/cursor if NODISPLAY is non-nil.

If `edoc-keynav-continuous' is non-nil move across page breaks."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (dotimes (_ n)
    (if (string-match "\\W*\\w+\\b"
		      edoc-keynav-text
		      edoc-keynav-point)
	(setq edoc-keynav-point
	      (match-end 0))
      (when edoc-keynav-continuous
	(let ((edoc-view-inhibit-redisplay
               (not edoc-keynav-pointer-as-cursor-minor-mode)))
	  (edoc-view-next-page)
	  (if edoc-keynav-lazy-load
	      (edoc-keynav-setup-buffer-locals))))))
  (unless nodisplay
    (edoc-keynav-display-region-cursor)))


(defun edoc-keynav-backward-word (&optional n nodisplay)
  "Move point backward N words and display region/cursor.
Move point to beginning of current word. If point is at beginning of a word or
at whitespace, move to beginning of previous word.

Do not display region/cursor if NODISPLAY is non-nil.

If `edoc-keynav-continuous' is non-nil move across page breaks."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let ((text (reverse edoc-keynav-text)))
    (dotimes (_ n)
      (if (string-match "\\W*\\w+\\b"
			text
			(- (length text)
			   edoc-keynav-point))
	  (setq edoc-keynav-point
		(- (length edoc-keynav-text)
		   (match-end 0)))
	(when edoc-keynav-continuous
	  (let ((edoc-view-inhibit-redisplay
                 (not edoc-keynav-pointer-as-cursor-minor-mode)))
	    (edoc-view-previous-page)
	    (if edoc-keynav-lazy-load
		(edoc-keynav-setup-buffer-locals))
	    (setq text (reverse edoc-keynav-text))
	    (edoc-keynav-end-of-page t)
	    (setq edoc-keynav-mark edoc-keynav-point))))))
  (unless nodisplay
    (edoc-keynav-display-region-cursor)))



;; ** Lines

(defun edoc-keynav-line-at-point ()
  "Return the line at point; 1 for the first line of page.
A line is whatever is separated by zero-width and -height character boundaries
in `edoc-keynav-charlayout', as these correspond to actual linebreaks more often
than the character boundaries corresponding to '\\n' characters."
  (--count (<= it edoc-keynav-point)
	   edoc-keynav-linestarts))


(defun edoc-keynav-next-line (&optional n)
  "Move point vertically down N lines and display region/cursor.
If `edoc-keynav-continuous' is non-nil move across page breaks (moving at most
one line into the adjacent page, truncating N)."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let ((inline (edoc-keynav-line-at-point))
	(lineends edoc-keynav-lineends)
	outline)
    ;; set the goal column (in terms of relative x-coordinate)
    (when (not (memq last-command
		     '(edoc-keynav-next-line edoc-keynav-previous-line)))
      (setq edoc-keynav-temporary-goal-column
	    (car (edoc-keynav-point-to-relative-pos))))
    ;; set the target line
    (if (> (+ inline n)
	   (length lineends))
	;; handle page break
	(if edoc-keynav-continuous
	    (let ((edoc-view-inhibit-redisplay
                   (not edoc-keynav-pointer-as-cursor-minor-mode)))
	      (edoc-view-next-page)
	      (if edoc-keynav-lazy-load
		  (edoc-keynav-setup-buffer-locals))
	      (setq outline 1))
	  (setq outline
		(length lineends)))
      (setq outline
	    (+ inline n)))
    ;; go to character on target line closest to goal column
    (setq edoc-keynav-point
	  (edoc-keynav-line-relative-xposition-to-ichar
	   outline
	   edoc-keynav-temporary-goal-column))
    (edoc-keynav-display-region-cursor)
    (setq this-command 'edoc-keynav-next-line)))


(defun edoc-keynav-previous-line (&optional n)
  "Move point vertically up N lines and display region/cursor.
If `edoc-keynav-continuous' is non-nil move across page breaks (moving at most
one line into the adjacent page, truncating N)."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let ((inline (edoc-keynav-line-at-point))
	outline)
    ;; set the goal column (in terms of relative x-coordinate)
    (when (not (memq last-command
		     '(edoc-keynav-next-line edoc-keynav-previous-line)))
      (setq edoc-keynav-temporary-goal-column
	    (car (edoc-keynav-point-to-relative-pos))))
    ;; set the target line
    (if (< (- inline n) 1)
	;; handle page break
	(if edoc-keynav-continuous
	    (let ((edoc-view-inhibit-redisplay
                   (not edoc-keynav-pointer-as-cursor-minor-mode)))
	      (edoc-view-previous-page)
	      (if edoc-keynav-lazy-load
		  (edoc-keynav-setup-buffer-locals))
	      (edoc-keynav-end-of-page t)
	      (setq edoc-keynav-mark edoc-keynav-point)
	      (setq outline
		    (length edoc-keynav-lineends)))
	  (setq outline 1))
      (setq outline
	    (- inline n)))
    ;; go to character on target line closest to goal column
    (setq edoc-keynav-point
	  (edoc-keynav-line-relative-xposition-to-ichar
	   outline
	   edoc-keynav-temporary-goal-column))
    (edoc-keynav-display-region-cursor)
    (setq this-command 'edoc-keynav-previous-line)))


(defun edoc-keynav-line-relative-xposition-to-ichar (line xpos)
  "Given line number LINE and XPOS, return the index of the closest character.
XPOS is a relative x-coordinate.

The search is restricted to characters on LINE and the return value is an index
in `edoc-keynav-charlayout'. XPOS is compared to the left edge of the character
bounding boxes."
  ;; MAYBE Can this be made faster?
  ;;       e.g. could pass the index of char at xpos and search left and right
  (let* ((istart (nth (1- line) edoc-keynav-linestarts))
	 (iend (nth (1- line) edoc-keynav-lineends))
	 (slice (-slice edoc-keynav-charlayout istart (1+ iend)))
	 (i-min-xdiff 0)
	 (min-xdiff 1)
	 i
	 xdiff)
    (setq i 0)
    (while (< i (length slice))
      (setq xdiff (abs (- xpos (car (nth 1 (nth i slice))))))
      (when (< xdiff min-xdiff)
	(setq min-xdiff xdiff)
	(setq i-min-xdiff i))
      (setq i (1+ i)))
    (+ istart i-min-xdiff)))


(defun edoc-keynav-forward-line (&optional n)
  "Move point forward N lines and display region/cursor.
Puts point at the beginning of the line, unless starting at the end of a line
in which case point is put at the end.

If `edoc-keynav-continuous' is non-nil move across page breaks (moving at most
one line into the adjacent page, truncating N).

Compared to `edoc-keynav-next-line' this function does only very basic vertical
alignment of point, making it slightly faster."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let ((inline (edoc-keynav-line-at-point))
	(inlineends edoc-keynav-lineends)
	(inpoint edoc-keynav-point)
	outline)
    ;; set the target line
    (if (> (+ inline n)
	   (length inlineends))
	;; handle page break
	(if edoc-keynav-continuous
	    (let ((edoc-view-inhibit-redisplay
                   (not edoc-keynav-pointer-as-cursor-minor-mode)))
	      (edoc-view-next-page)
	      (if edoc-keynav-lazy-load
		  (edoc-keynav-setup-buffer-locals))
	      (setq outline 1))
	  (setq outline
		(length inlineends)))
      (setq outline
	    (+ inline n)))
    ;; goto end of next line if starting at end of a line
    (if (-contains? inlineends inpoint)
	(setq edoc-keynav-point
	      (nth (1- outline)
		   edoc-keynav-lineends))
      ;; else go to beginning of next line
      (setq edoc-keynav-point
	    (nth (1- outline)
		 edoc-keynav-linestarts))))
  (edoc-keynav-display-region-cursor))


(defun edoc-keynav-backward-line (&optional n)
  "Move point backward N lines and display region/cursor.
Puts point at the beginning of the line, unless starting at the end of a line
in which case point is put at the end.

If `edoc-keynav-continuous' is non-nil move across page breaks (moving at most
one line into the adjacent page, truncating N).

Compared to `edoc-keynav-previous-line' this function does only very basic
vertical alignment of point, making it slightly faster."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let ((inline (edoc-keynav-line-at-point))
	(inlineends edoc-keynav-lineends)
	(inpoint edoc-keynav-point)
	outline)
    ;; set the target line
    (if (< (1- inline) n)
	;; handle page break
	(if edoc-keynav-continuous
	    (let ((edoc-view-inhibit-redisplay
                   (not edoc-keynav-pointer-as-cursor-minor-mode)))
	      (edoc-view-previous-page)
	      (if edoc-keynav-lazy-load
		  (edoc-keynav-setup-buffer-locals))
	      (edoc-keynav-end-of-page t)
	      (setq edoc-keynav-mark edoc-keynav-point)
	      (setq outline
		    (length edoc-keynav-lineends)))
	  (setq outline 1))
      (setq outline
	    (- inline n)))
    ;; goto end of next line if starting at end of a line
    (if (-contains? inlineends inpoint)
	(setq edoc-keynav-point
	      (nth (1- outline)
		   edoc-keynav-lineends))
      ;; else go to beginning of next line
      (setq edoc-keynav-point
	    (nth (1- outline)
		 edoc-keynav-linestarts))))
  (edoc-keynav-display-region-cursor))


(defun edoc-keynav-beginning-of-line (&optional nodisplay)
  "Move point to beginning of current line and display region/cursor.
Do not display region/cursor if NODISPLAY is non-nil."
  (interactive)
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (setq edoc-keynav-point
	(nth (1- (edoc-keynav-line-at-point))
	     edoc-keynav-linestarts))
  (unless nodisplay
    (edoc-keynav-display-region-cursor)))


(defun edoc-keynav-end-of-line (&optional nodisplay)
  "Move point to end of current line and display region/cursor.
Do not display region/cursor if NODISPLAY is non-nil."
  (interactive)
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (setq edoc-keynav-point
	(nth (1- (edoc-keynav-line-at-point))
	     edoc-keynav-lineends))
  (unless nodisplay
    (edoc-keynav-display-region-cursor)))


(defun edoc-keynav-middle-of-line ()
  "Move point to middle of current line and display region/cursor.
Line width is measured in number of characters."
  (interactive)
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let* ((line (1- (edoc-keynav-line-at-point)))
	 (begin (nth line  edoc-keynav-linestarts))
         (end (nth line edoc-keynav-lineends))
         (middle (/ (+ end begin) 2)))
    (setq edoc-keynav-point middle))
  (edoc-keynav-display-region-cursor))



;; ** Textregions

(defun edoc-keynav-textregion-at-point ()
  "Returns the index of the textregion at point; 1 for the first on page.

Textregions are construed by poppler and often correspond to lines, but may be
larger or (less often) smaller. Moreover, they tend to be ordered left to right
and then top to bottom, while lines tend to follow the logical flow of the text
more. Textregions can also overlap substantially, which may cause cycles when
attempting to move between them."
  (let ((pointpos (edoc-keynav-point-to-relative-pos)))
    (1+ (--find-index
	 (edoc-util-edges-inside-p it pointpos)
	 edoc-keynav-textregions))))


(defun edoc-keynav-forward-textregion (&optional n)
  "Move point forward one textregion and display region/cursor.
With argument N move forward n textregions. Point is placed at the first
character of the textregion.

If `edoc-keynav-continuous' is non-nil move across page breaks (moving at most
one textregion into the adjacent page, truncating N).

For more about textregions see `edoc-keynav-textregion-at-point'."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let* ((intextregion (edoc-keynav-textregion-at-point))
	 (textregions edoc-keynav-textregions)
	 (outtextregion
	  (if (> (+ intextregion n)
		 (length textregions))
	      (if edoc-keynav-continuous
		  (let ((edoc-view-inhibit-redisplay
                         (not edoc-keynav-pointer-as-cursor-minor-mode)))
		    (edoc-view-next-page)
		    (if edoc-keynav-lazy-load
			(edoc-keynav-setup-buffer-locals))
		    (setq textregions edoc-keynav-textregions)
		    1)
		(length textregions))
	    (+ intextregion n)))
	 (textregion (nth (1- outtextregion)
			  textregions))
	 (xpos (nth 0 textregion))
	 (ypos (/ (+ (nth 1 textregion)
		     (nth 3 textregion))
		  2)))
    (setq edoc-keynav-point
	  (edoc-keynav-relative-pos-to-ichar
	   (cons xpos ypos)))
    (edoc-keynav-display-region-cursor)))


(defun edoc-keynav-backward-textregion (&optional n)
  "Move point backward one textregion and display region/cursor.
With argument N move backward n textregions. Point is placed at the first
character of the textregion.

If `edoc-keynav-continuous' is non-nil move across page breaks (moving at most
one textregion into the adjacent page, truncating N).

For more about textregions see `edoc-keynav-textregion-at-point'."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let* ((intextregion (edoc-keynav-textregion-at-point))
	 (textregions edoc-keynav-textregions)
	 (outtextregion
	  (if (< (- intextregion n)
		 1)
	      ;; handle page break
	      (if edoc-keynav-continuous
		  (let ((edoc-view-inhibit-redisplay
                         (not edoc-keynav-pointer-as-cursor-minor-mode)))
		    (edoc-view-previous-page)
		    (if edoc-keynav-lazy-load
			(edoc-keynav-setup-buffer-locals))
		    (edoc-keynav-end-of-page t)
		    (setq edoc-keynav-mark edoc-keynav-point)
		    (setq textregions edoc-keynav-textregions)
		    (length textregions))
		1)
	    (- intextregion n)))
	 (textregion (nth (1- outtextregion)
			  textregions))
	 (xpos (nth 0 textregion))
	 (ypos (/ (+ (nth 1 textregion)
		     (nth 3 textregion))
		  2)))
    (setq edoc-keynav-point
	  (edoc-keynav-relative-pos-to-ichar
	   (cons xpos ypos)))
    (edoc-keynav-display-region-cursor)))


(defun edoc-keynav-beginning-of-textregion ()
  "Move point to beginning of current textregion and display region/cursor.
For more about textregions see `edoc-keynav-textregion-at-point'."
  (interactive)
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let* ((pointpos (edoc-keynav-point-to-relative-pos))
	 (textregion (--first
		      (edoc-util-edges-inside-p it pointpos)
		      edoc-keynav-textregions))
	 (pos (cons (nth 0 textregion) (nth 1 textregion))))
    (setq edoc-keynav-point
	  (edoc-keynav-relative-pos-to-ichar pos))
    (edoc-keynav-display-region-cursor)))


(defun edoc-keynav-end-of-textregion ()
  "Move point to end of current textregion and display region/cursor.
For more about textregions see `edoc-keynav-textregion-at-point'."
  (interactive)
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let* ((pointpos (edoc-keynav-point-to-relative-pos))
	 (textregion (--first
		      (edoc-util-edges-inside-p it pointpos)
		      edoc-keynav-textregions))
	 (pos (cons (nth 2 textregion) (nth 3 textregion))))
    (setq edoc-keynav-point
	  (edoc-keynav-relative-pos-to-ichar pos))
    (edoc-keynav-display-region-cursor)))



;; ** Sentences

(defun edoc-keynav-forward-sentence (&optional n nodisplay)
  "Move point forward N sentences and display region/cursor.
Move point to end of current sentence. If point is at end of a sentence or at
whitespace, move to end of next sentence.

Do not display region/cursor if NODISPLAY is non-nil.

If `edoc-keynav-continuous' is non-nil move across page breaks."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let ((case-fold-search nil)) ;; make sure case is not ignored
    (dotimes (_ n)
      (if (string-match
	   edoc-keynav-sentence-end
	   edoc-keynav-text
	   edoc-keynav-point)
	  (setq edoc-keynav-point
		(or (match-end 1) (match-end 2) (match-end 3)))
	(if (and edoc-keynav-continuous
		 (equal edoc-keynav-point (1- (length edoc-keynav-text))))
	    (let ((edoc-view-inhibit-redisplay
                   (not edoc-keynav-pointer-as-cursor-minor-mode)))
	      (edoc-view-next-page)
	      (if edoc-keynav-lazy-load
		  (edoc-keynav-setup-buffer-locals)))
	  (progn
	    (unless nodisplay (message "End of page"))
	    (setq edoc-keynav-point (1- (length edoc-keynav-text))))))))
  (unless nodisplay
    (edoc-keynav-display-region-cursor)))


(defun edoc-keynav-backward-sentence (&optional n nodisplay)
  "Move point backward N sentences and display region/cursor.
Move point to beginning of current sentence. If point is at beginning of a
sentence or at whitespace, move to beginning of previous sentence.

Do not display region/cursor if NODISPLAY is non-nil.

If `edoc-keynav-continuous' is non-nil move across page breaks."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let ((case-fold-search nil) ;; make sure case is not ignored
	(rev-page-text (reverse edoc-keynav-text)))
    (dotimes (_ n)
      (if (string-match
	   edoc-keynav-sentence-start
	   rev-page-text
	   (- (length rev-page-text) edoc-keynav-point))
	  (setq edoc-keynav-point
		(- (length rev-page-text)
		   (or (match-beginning 1)
		       (match-beginning 2)
		       (match-beginning 3))))
	(if (and edoc-keynav-continuous
		 (equal edoc-keynav-point 0))
	    (let ((edoc-view-inhibit-redisplay
                   (not edoc-keynav-pointer-as-cursor-minor-mode)))
	      (edoc-view-previous-page)
	      (if edoc-keynav-lazy-load
		  (edoc-keynav-setup-buffer-locals))
	      (setq rev-page-text (reverse edoc-keynav-text))
	      (edoc-keynav-end-of-page t)
	      (setq edoc-keynav-mark edoc-keynav-point))
	  (progn
	    (unless nodisplay (message "Beginning of page"))
	    (setq edoc-keynav-point 0))))))
  (unless nodisplay
    (edoc-keynav-display-region-cursor)))



;; ** Paragraphs

(defun edoc-keynav-get-page-paragraphs (&optional dxs-round-to dys-round-to
						 min-indent max-indent
						 max-dx-discrepancy
						 min-dy-discrepancy)
  "Returns a list of starting positions of paragraphs on current pdf page.

The starting positions are given in terms of indices in
`edoc-keynav-charlayout'. They are determined heuristically using the
distribution of horizontal and vertical spacing between characters at the
beginning of lines on the page: Anything with larger vertical spacing to the
previous line than the most common spacing between lines (subject to suitable
rounding), or with an indent of reasonable size (symmetric with respect to the
previous and next line), is considered a paragraph start.

DXS-ROUND-TO and DYS-ROUND-TO set the values the horizontal and vertical gaps
between linestarts should be rounded to. The rounded values are then used to
determine frequent values and compare gaps, so the amount of rounding
determines what counts as noise and what is interpreted as meaningful
differences.

MIN-INDENT and MAX-INDENT set the range of horizontal linestart gap sizes that
are interpreted as potential paragraph breaking indents.

MAX-DX-DISCREPANCY sets the maximal allowed discrepancy between the horizontal
linestart gap to the previous and next line for an indent to be considered
symmetric and hence a potential paragraph break (this helps when pages are not
straight).

MIN-DY-DISCREPANCY sets how much larger than the most common vertical linestart
gap a vertical linestart gap has to be before being considered a paragraph
break.

Parameter; default value; unit:
DXS-ROUND-TO; 0.01; in fraction of page width
DYS-ROUND-TO; 0.02; in fraction of page height
MIN-INDENT; 2; in units of DXS-ROUND-TO
MAX-INDENT; 5; in units of DXS-ROUND-TO
MAX-DX-DISCREPANCY; 1; in units of DXS-ROUND-TO
MIN-DY-DISCREPANCY; 1; in units of DYS-ROUND-TO"
  
  ;; MAYBE would it be better to determine "paragraph gap" once per document
  ;;       and base it on more than one page?
  ;;       then one could maybe use second-most frequent xpos
  ;;       but the per-page approach has advantages too,
  ;;       since it's more adaptive
  ;; MAYBE in some pdfs vertical spacing gives headings
  ;;       and horizontal spacing paragraphs - might want both separately
  ;;       i.e. arguments horizontal-only-p and vertical-only-p?
  
  ;; default values:
  (unless dxs-round-to (setq dxs-round-to 0.01))
  (unless dys-round-to (setq dys-round-to 0.02))
  (unless min-indent (setq min-indent 2))
  (unless max-indent (setq max-indent 5))
  (unless max-dx-discrepancy (setq max-dx-discrepancy 1))
  (unless min-dy-discrepancy (setq min-dy-discrepancy 1))
  
  (let* ((linestarts edoc-keynav-linestarts)
	 (startedges
	  ;; edges of linestart characters
	  (--map
	   (car (cdr
		 (nth it edoc-keynav-charlayout)))
	   linestarts))
	 (dys
	  ;; vertical gaps between linestarts
	  (--zip-with
	   (round (- (nth 1 other) (nth 1 it)) dys-round-to)
	   (-butlast startedges)
	   (cdr startedges)))
	 (dxs
	  ;; horizontal gaps between linestarts
	  (--zip-with
	   (round (- (nth 0 other) (nth 0 it)) dxs-round-to)
	   (-butlast startedges)
	   (cdr startedges)))
	 ;; (xs
	 ;;  ;; horizontal positions of linestarts
	 ;;  (--map
	 ;;   (round (nth 0 it) dxs-round-to)
	 ;;   startedges))
	 (most-freq-dy
	  (car (-last-item
		(edoc-keynav-get-frequency-distribution dys))))
	 ;; (second-most-freq-dx
	 ;;  ;; need more than one page for this to be useful
	 ;;  ;; most frequent should always be 0 (but isn't...)
	 ;;  (car (-last-item
	 ;; 	(-butlast
	 ;; 	 (edoc-keynav-get-frequency-distribution
	 ;; 	  (--map (abs it) dxs))))))
	 ;; (most-freq-x
	 ;;  ;; useless in multicolumn pdfs...
	 ;;  (car (-last-item
	 ;; 	(edoc-keynav-get-frequency-distribution xs))))
	 (large-ygaps
	  ;; linestarts after ygaps that are larger than most-freq-dy
	  (--map
	   (nth (1+ it) linestarts)
	   (--find-indices
	    (>= (- it min-dy-discrepancy) most-freq-dy)
	    dys)))
	 ;; (large-xpos
	 ;;  ;; linestarts with xpos larger than most-freq-x
	 ;;  (--map
	 ;;   (nth it linestarts)
	 ;;   (--find-indices
	 ;;    (> it most-freq-x)
	 ;;    xs)))
	 (symmetric-xgaps
	  ;; linestarts with symmetric xpos gaps around them (i.e. indents)
	  (--filter
	   it ;; remove nil elements set in if-clause below
	   (--map-indexed
	    ;; return linestart index or nil
	    (let ((next-it (nth (1+ it-index) dxs)))
	      (if (and
		   ;; allow discrepancy of max-dx-discrepancy here
		   ;; (helps when pages are not straight)
		   (<= (abs (- it (* -1 next-it))) max-dx-discrepancy)
		   ;; avoids some false symmetric indents due to noise
		   (>= it min-indent)
		   (<= it max-indent))
		  (nth (1+ it-index) linestarts)
		nil))
	    (-butlast dxs))))
	 )
    ;; (message "dxs:\n%s\nsymmetric-xgaps:\n%s\ndys:\n%s\nlarge-ygaps:\n%s"
    ;; 	     dxs symmetric-xgaps dys large-ygaps)
    (sort
     (-union (list 0)
	     (-union
	      large-ygaps
	      symmetric-xgaps))
     '<)))


(defun edoc-keynav-get-frequency-distribution (list)
  "Get the frequency distribution of the elements in LIST.
Returns a list of cons cells (element . freq) corresponding to the least to
most frequent elements and their frequencies."
  ;; taken from:
  ;; https://stackoverflow.com/questions/6050033/elegant-way-to-count-items
  (let* ((test #'equal)
	 (key nil)
	 (h (make-hash-table :test test)))
    (dolist (x list)
      (let ((key (if key (funcall key x) x)))
        (puthash key (1+ (gethash key h 0)) h)))
    (let ((r nil))
      (maphash #'(lambda (k v) (push (cons k v) r)) h)
      (sort r #'(lambda (x y) (< (cdr x) (cdr y)))))))


(defun edoc-keynav-paragraph-at-point ()
  "Return the paragraph at point; 1 for the first paragraph of page.
Paragraphs are determined by `edoc-keynav-get-page-paragraphs'; their starting
indices (in `edoc-keynav-charlayout') are stored in `edoc-keynav-parstarts'."
  (--count (<= it edoc-keynav-point)
	   edoc-keynav-parstarts))


(defun edoc-keynav-forward-paragraph (&optional n nodisplay)
  "Move point forward one paragraph and display region/cursor.
With argument N move forward n paragraphs. Puts point at the beginning of the
 paragraph, unless starting at the end of a paragraph in which case point is
put at the end.

Do not display region/cursor if NODISPLAY is non-nil.

If `edoc-keynav-continuous' is non-nil move across page breaks (moving at most
one paragraph into the adjacent page, truncating N)."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let ((inpar (edoc-keynav-paragraph-at-point))
	(inparends edoc-keynav-parends)
	(inpoint edoc-keynav-point)
	outpar)
    ;; set the target paragraph
    (if (> (+ inpar n)
	   (length edoc-keynav-parends))
	;; handle page break
	(if edoc-keynav-continuous
	    (progn
	      ;; change page and update buffer-locals
	      ;; but redisplay is done through display-cursor below
	      (let ((edoc-view-inhibit-redisplay
                     (not edoc-keynav-pointer-as-cursor-minor-mode)))
		(edoc-view-next-page)
		(if edoc-keynav-lazy-load
		    (edoc-keynav-setup-buffer-locals)))
	      (setq outpar 1))
	  (setq outpar
		(length edoc-keynav-parends)))
      (setq outpar
	    (+ inpar n)))
    ;; goto end of next paragraph if starting at end of a paragraph
    (if (-contains? inparends inpoint)
	(setq edoc-keynav-point
	      (nth (1- outpar)
		   edoc-keynav-parends))
      ;; else go to beginning of next paragraph
      (setq edoc-keynav-point
	    (nth (1- outpar)
		 edoc-keynav-parstarts))))
  (unless nodisplay
    (edoc-keynav-display-region-cursor)))


(defun edoc-keynav-backward-paragraph (&optional n nodisplay)
  "Move point backward one paragraph and display region/cursor.
With argument N move backward n paragraphs. Puts point at the beginning of the
paragraph, unless starting at the end of a paragraph in which case point is put
at the end.

Do not display region/cursor if NODISPLAY is non-nil.

If `edoc-keynav-continuous' is non-nil move across page breaks (moving at most
one paragraph into the adjacent page, truncating N)."
  (interactive "p")
  (unless n (setq n 1))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let ((inpar (edoc-keynav-paragraph-at-point))
	(inparends edoc-keynav-parends)
	(inpoint edoc-keynav-point)
	outpar)
    ;; set the target paragraph
    (if (< (- inpar n)
	   1)
	;; handle page break
	(if edoc-keynav-continuous
	    (progn
	      ;; change page and update buffer-locals
	      ;; but redisplay is done through display-cursor below
	      (let ((edoc-view-inhibit-redisplay
                     (not edoc-keynav-pointer-as-cursor-minor-mode)))
		(edoc-view-previous-page)
		(if edoc-keynav-lazy-load
		    (edoc-keynav-setup-buffer-locals))
		(edoc-keynav-end-of-page t)
		(setq edoc-keynav-mark edoc-keynav-point))
	      (setq outpar (length edoc-keynav-parends)))
	  (setq outpar 1))
      (setq outpar
	    (- inpar n)))
    ;; goto end of previous paragraph if starting at end of a paragraph
    (if (-contains? inparends inpoint)
	(setq edoc-keynav-point
	      (nth (1- outpar)
		   edoc-keynav-parends))
      ;; else go to beginning of previous paragraph
      (setq edoc-keynav-point
	    (nth (1- outpar)
		 edoc-keynav-parstarts)))
    (unless nodisplay
      (edoc-keynav-display-region-cursor))))


(defun edoc-keynav-beginning-of-paragraph (&optional nodisplay)
  "Move point to beginning of current paragraph and display region/cursor.
Do not display region/cursor if NODISPLAY is non-nil."
  (interactive)
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))  
  (setq edoc-keynav-point
	(nth (1- (edoc-keynav-paragraph-at-point))
	     edoc-keynav-parstarts))
  (unless nodisplay
    (edoc-keynav-display-region-cursor)))


(defun edoc-keynav-end-of-paragraph (&optional nodisplay)
  "Move point to end of current paragraph and display region/cursor.
Do not display region/cursor if NODISPLAY is non-nil."
  (interactive)
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (setq edoc-keynav-point
	(nth (1- (edoc-keynav-paragraph-at-point))
	     edoc-keynav-parends))
  (unless nodisplay
    (edoc-keynav-display-region-cursor)))


(defun edoc-keynav-middle-of-paragraph (&optional nodisplay)
  "Move point to middle of current paragraph and display region/cursor.
Paragraph width is measured in number of characters.

Do not display region/cursor if NODISPLAY is non-nil."
  (interactive)
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (let* ((paragraph (1- (edoc-keynav-paragraph-at-point)))
	 (begin (nth paragraph edoc-keynav-parstarts))
         (end (nth paragraph edoc-keynav-parends))
         (middle (/ (+ end begin) 2)))
    (setq edoc-keynav-point middle))
  (unless nodisplay
    (edoc-keynav-display-region-cursor)))



;; ** Pages

(defun edoc-keynav-beginning-of-page (&optional nodisplay)
  "Move point to beginning of current page and display region/cursor.
Do not display region/cursor if NODISPLAY is non-nil."
  (interactive)
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (setq edoc-keynav-point 0)
  (unless nodisplay
    (edoc-keynav-display-region-cursor)))


(defun edoc-keynav-end-of-page (&optional nodisplay)
  "Move point to end of current page and display region/cursor.
Do not display region/cursor if NODISPLAY is non-nil."
  (interactive)
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (setq edoc-keynav-point
	(1- (length edoc-keynav-charlayout)))
  (unless nodisplay
    (edoc-keynav-display-region-cursor)))


(defun edoc-keynav-middle-of-page (&optional nodisplay)
  "Move point to middle of current page and display region/cursor.
Do not display region/cursor if NODISPLAY is non-nil."
  (interactive)
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (setq edoc-keynav-point
	(/ (1- (length edoc-keynav-charlayout)) 2))
  (unless nodisplay
    (edoc-keynav-display-region-cursor)))


;; * Mark

(defun edoc-keynav-set-mark-command (&optional arg)
  "Set the mark where point is or jump to the mark.
With no prefix argument, set the mark at point. With prefix argument, jump to
the mark."
  ;; MAYBE implement more fully with mark ring etc.
  (interactive "p")
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))  
  (if (equal arg 4)
      (progn
	(setq edoc-keynav-point edoc-keynav-mark)
	(edoc-keynav-display-region-cursor))
    (progn
      (setq edoc-keynav-mark edoc-keynav-point)
      (message "Mark set")
      (if (and edoc-keynav-transient-mark-mode (not edoc-keynav-mark-active-p))
	  (setq edoc-keynav-mark-active-p t)
	(when edoc-keynav-transient-mark-mode
	  (edoc-keynav-display-region-cursor))))))


(defun edoc-keynav-exchange-point-and-mark (&optional nodisplay)
  "Put the mark where point is now, and point where the mark is now."
  (interactive)
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))  
  (let ((omark edoc-keynav-mark)
        (point edoc-keynav-point))
    (edoc-keynav-set-mark-command)
    (setq edoc-keynav-point omark)
    (unless nodisplay 
    (edoc-keynav-display-region-cursor))))


(defun edoc-keynav-transient-mark-mode (&optional arg)
  "Toggle Transient Mark mode.
With positive ARG activate transient mark mode; with negative deactivate it."
  ;; MAYBE implement more fully
  (interactive "P")
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (if (null arg)
      (if edoc-keynav-transient-mark-mode
	  (progn
	    (setq edoc-keynav-transient-mark-mode nil)
	    (message "Pdf-Keynav-Trasient-Mark mode disabled"))
	(setq edoc-keynav-transient-mark-mode t)
	(message "Pdf-Keynav-Trasient-Mark mode enabled"))
    (if (> (prefix-numeric-value arg) 0)
	(progn
	  (setq edoc-keynav-transient-mark-mode t)
	  (message "Pdf-Keynav-Trasient-Mark mode enabled"))
      (setq edoc-keynav-transient-mark-mode nil)
      (message "Pdf-Keynav-Trasient-Mark mode disabled")))
  (edoc-keynav-display-region-cursor))


(defun edoc-keynav-deactivate-mark ()
  "Deactivate the mark."
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (setq edoc-keynav-mark-active-p nil)
  (edoc-keynav-display-region-cursor))


(defun edoc-keynav-keyboard-quit ()
  "Wraps `keyboard-quit' to also hide the region or cursor where applicable.
If `edoc-keynav-transient-mark-mode' is non-nil, or the last command displayed a
region, hide the region and display the cursor. Else redisplay the page to hide
the cursor and activate hotspots (clickability/tooltips for annotations/links)
again."
  ;; MAYBE better if edoc-keynav-transient-mark-mode is a minor mode calling:
  ;; (advice-add 'keyboard-quit :before #'edoc-keynav-deactivate-mark)
  ;; (advice-remove 'keyboard-quit #'edoc-keynav-deactivate-mark)
  (interactive)
  (if edoc-keynav-transient-mark-mode
      (progn
	(edoc-keynav-deactivate-mark)
	(if (memq last-command
		  '(edoc-keynav-keyboard-quit))
	    (edoc-view-redisplay)))	    
    (if (and (not (equal edoc-keynav-point edoc-keynav-mark))
	     (memq last-command
		   '(edoc-keynav-mouse-set-region
		     edoc-keynav-mouse-extend-region
		     edoc-keynav-mouse-select-word
		     edoc-keynav-mouse-select-line
		     edoc-keynav-mouse-select-sentence
		     edoc-keynav-mouse-select-paragraph
		     edoc-keynav-select-word
		     edoc-keynav-select-line
		     edoc-keynav-select-sentence
		     edoc-keynav-select-paragraph)))
	(edoc-keynav-display-region-cursor)
      (edoc-view-redisplay)))
  (keyboard-quit))



;; * Select

(defun edoc-keynav-select-word ()
  "Select the word at point.
Puts mark at beginning of word and point at end, and displays region."
  (interactive)
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (edoc-keynav-forward-word nil t)
  (edoc-keynav-set-mark-command)
  (edoc-keynav-backward-word nil t)
  (edoc-keynav-exchange-point-and-mark t)
  (edoc-view-display-region
   (list (edoc-keynav-get-region-rpos))))


(defun edoc-keynav-select-line ()
  "Select the line at point.
Puts mark at beginning of line and point at end, and displays region."
  (interactive)
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))     
  (edoc-keynav-beginning-of-line t)
  (edoc-keynav-set-mark-command)
  (edoc-keynav-end-of-line t)
  (edoc-view-display-region
   (list (edoc-keynav-get-region-rpos))))


(defun edoc-keynav-select-sentence ()
  "Select the sentence at point.
Puts mark at beginning of sentence and point at end, and displays region."
  (interactive)
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))     
  (edoc-keynav-forward-sentence nil t)
  (edoc-keynav-set-mark-command)
  (edoc-keynav-backward-sentence nil t)
  (edoc-keynav-exchange-point-and-mark t)
  (edoc-view-display-region
   (list (edoc-keynav-get-region-rpos))))


(defun edoc-keynav-select-paragraph ()
  "Select the paragraph at point.
Puts mark at beginning of paragraph and point at end, and displays region."
  (interactive)
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))     
  (edoc-keynav-beginning-of-paragraph t)
  (edoc-keynav-set-mark-command)
  (edoc-keynav-end-of-paragraph t)
  (edoc-view-display-region
   (list (edoc-keynav-get-region-rpos))))


(defun edoc-keynav-select-page ()
  "Select the current page.
Puts mark at beginning of page and point at end, and displays region."
  (interactive)
  (edoc-keynav-beginning-of-page t)
  (edoc-keynav-set-mark-command)
  (edoc-keynav-end-of-page t)
  (edoc-view-display-region
   (list (edoc-keynav-get-region-rpos))))



;; * Select using mouse

;; ** Click

(defun edoc-keynav-mouse-set-point (event &optional nodisplay)
  "Set point at mouse event position and display region/cursor.
This command has to be bound to a mouse event (e.g. a click).

Do not display region/cursor if NODISPLAY is non-nil.

Unless `edoc-keynav-no-find-closest-char' is non-nil, go to the closest
character when none is found at event position."
  (interactive "@e")
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (setq edoc-keynav-point
	(edoc-keynav-pixel-pos-to-ichar
	 (posn-object-x-y
	  (event-start event))
	 edoc-keynav-no-find-closest-char))
  (unless (or nodisplay edoc-keynav-pointer-as-cursor-minor-mode)
    (edoc-keynav-display-region-cursor)))


(defun edoc-keynav-mouse-select-word (event)
  "Select word at mouse event position.
This command has to be bound to a mouse event (e.g. a click).

Unless `edoc-keynav-no-find-closest-char' is non-nil, start at closest
character when none is found at event position."
  (interactive "@e")
  (edoc-keynav-mouse-set-point event t)
  (edoc-keynav-select-word))


(defun edoc-keynav-mouse-select-line (event)
  "Select line at mouse event position.
This command has to be bound to a mouse event (e.g. a click).

Unless `edoc-keynav-no-find-closest-char' is non-nil, start at closest
character when none is found at event position."
  (interactive "@e")
  (edoc-keynav-mouse-set-point event t)
  (edoc-keynav-select-line))


(defun edoc-keynav-mouse-select-sentence (event)
  "Select sentence at mouse event position.
This command has to be bound to a mouse event (e.g. a click).

Unless `edoc-keynav-no-find-closest-char' is non-nil, start at closest
character when none is found at event position."
  (interactive "@e")
  (edoc-keynav-mouse-set-point event t)
  (edoc-keynav-select-sentence))


(defun edoc-keynav-mouse-select-paragraph (event)
  "Select paragraph at mouse event position.
This command has to be bound to a mouse event (e.g. a click).

Unless `edoc-keynav-no-find-closest-char' is non-nil, start at closest
character when none is found at event position."
  (interactive "@e")
  (edoc-keynav-mouse-set-point event t)
  (edoc-keynav-select-paragraph))



;; ** Drag

(defun edoc-keynav-mouse-set-region (event &optional allow-extend-p
                                          rectangle-p)
  "Select a region of text using the mouse with mouse event EVENT.
This is a version of `edoc-view-mouse-set-region' adapted to fit into
`edoc-keynav-minor-mode'.

This function should be bound to a down-mouse event. If dragging occurs after
mouse-down, mark is set to the start position of the region dragged over and
point to the end, plus in `edoc-keynav-transient-mark-mode' the region is
activated. If no dragging occurs only point is set, plus in
`edoc-keynav-transient-mark-mode' the region is deactivated. Finally the
region/cursor is displayed.

Allow for stacking of regions, if ALLOW-EXTEND-P is non-nil. See
`edoc-keynav-mouse-extend-region'. In order to be compatible with this behavior,
the region is also stored as a list of lists of edges in
`edoc-view-active-region'.

Create a rectangular region, if RECTANGLE-P is non-nil."
  (interactive "@e")
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (setq edoc-view--have-rectangle-region rectangle-p)
  (unless (and (eventp event)
               (mouse-event-p event))
    (signal 'wrong-type-argument (list 'mouse-event-p event)))
  (unless (and allow-extend-p
               (or (null (get this-command 'edoc-view-region-window))
                   (equal (get this-command 'edoc-view-region-window)
                          (selected-window))))
    (setq edoc-view-active-region nil))
  (put this-command 'edoc-view-region-window
       (selected-window))
  
  (let* ((window (selected-window))
         (pos (event-start event))
         (begin-inside-image-p t)
         (begin (if (posn-image pos)
                    (posn-object-x-y pos)
                  (setq begin-inside-image-p nil)
                  (posn-x-y pos)))
         (abs-begin (posn-x-y pos))
         edoc-view-continuous
         region)
    (if (edoc-util-track-mouse-dragging (event 0.05)
          (let* ((pos (event-start event))
                 (end (posn-object-x-y pos))
                 (end-inside-image-p
                  (and (eq window (posn-window pos))
                       (posn-image pos))))
            (when (or end-inside-image-p
                      begin-inside-image-p)
              (cond
               ((and end-inside-image-p
                     (not begin-inside-image-p))
                ;; Started selection outside the image, setup begin.
                (let* ((xy (posn-x-y pos))
                       (dxy (cons (- (car xy) (car begin))
                                  (- (cdr xy) (cdr begin))))
                       (size (edoc-view-image-size t)))
                  (setq begin (cons (max 0 (min (car size)
                                                (- (car end) (car dxy))))
                                    (max 0 (min (cdr size)
                                                (- (cdr end) (cdr dxy)))))
                        ;; Store absolute position for later.
                        abs-begin (cons (- (car xy)
                                           (- (car end)
                                              (car begin)))
                                        (- (cdr xy)
                                           (- (cdr end)
                                              (cdr begin))))
                        begin-inside-image-p t)))
               ((and begin-inside-image-p
                     (not end-inside-image-p))
                ;; Moved outside the image, setup end.
                (let* ((xy (posn-x-y pos))
                       (dxy (cons (- (car xy) (car abs-begin))
                                  (- (cdr xy) (cdr abs-begin))))
                       (size (edoc-view-image-size t)))
                  (setq end (cons (max 0 (min (car size)
                                              (+ (car begin) (car dxy))))
                                  (max 0 (min (cdr size)
                                              (+ (cdr begin) (cdr dxy)))))))))
              (let ((iregion (if rectangle-p
                                 (list (min (car begin) (car end))
                                       (min (cdr begin) (cdr end))
                                       (max (car begin) (car end))
                                       (max (cdr begin) (cdr end)))
                               (list (car begin) (cdr begin)
                                     (car end) (cdr end)))))
                (setq region
                      (edoc-util-scale-pixel-to-relative iregion))
		;;(message "region: %s" region)
                (edoc-view-display-region
                 (cons region edoc-view-active-region)
                 rectangle-p)
                (edoc-util-scroll-to-edges iregion)))))
	;; end of if condition for mouse dragging
	(progn
	  ;; then part
	  (setq edoc-view-active-region
		(append edoc-view-active-region
			(list region)))
	  ;; set mark and point
	  (setq edoc-keynav-mark
		(edoc-keynav-relative-pos-to-ichar
		 (cons (nth 0 region)
		       (nth 1 region))))
	  (message "Mark set")
	  (setq edoc-keynav-point
		(edoc-keynav-relative-pos-to-ichar
		 (cons (nth 2 region)
		       (nth 3 region))))
	  (when (and edoc-keynav-transient-mark-mode
		     (not edoc-keynav-mark-active-p))
	    (setq edoc-keynav-mark-active-p t)))
      ;; else part
      (when (and edoc-keynav-transient-mark-mode
		 edoc-keynav-mark-active-p)
	(setq edoc-keynav-mark-active-p nil))
      (setq edoc-keynav-point
	    (edoc-keynav-pixel-pos-to-ichar begin))
      (if edoc-keynav-pointer-as-cursor-minor-mode
          (edoc-view-redisplay)
        (edoc-keynav-display-region-cursor)))))


(defun edoc-keynav-mouse-extend-region (event)
  "Extend the currently active region with mouse event EVENT.
Adaptation of `edoc-view-mouse-extend-region'.

This additionally saves the region in the form of a list of lists of edges in
`edoc-view-active-region'. Commands that act upon the region will make use
`edoc-view-active-region' only if the last command was
`edoc-keynav-mouse-extend-region', hence this method of extending the region
cannot be combined with other commands. Mark and point will be at the beginning
and end of the last selection made."
  (interactive "@e")
  (edoc-keynav-mouse-set-region
   event t edoc-view--have-rectangle-region))


;; ** Hover

(defun edoc-keynav-mouse-set-point-from-pointer ()
  "Set the point to the character under the mouse pointer."
  (interactive)  
  (setq edoc-keynav-point
        (edoc-keynav-pixel-pos-to-ichar
         (edoc-keynav-mouse-pixel-pos-to-image-pixel-pos
          (cdr (mouse-pixel-position))))))
         
(defun edoc-keynav-mouse-pixel-pos-to-image-pixel-pos (mppos)
  "Convert absolute mouse-pixel-position MPPOS to pixel image coordinates."
  (let* ((outer-edges (frame-edges (selected-frame) 'outer-edges))
         (inner-edges-abs (window-edges nil nil t t))
         (inner-edges-rel (window-edges nil nil nil t))
         (window-left-offset (- (nth 0 inner-edges-abs)
                                (nth 0 outer-edges)))
         (window-top-offset (nth 1 inner-edges-rel))
         (image-displayed-edges (edoc-util-image-displayed-edges))
         (image-width (car (edoc-view-image-size)))
         (image-left-offset (/ (- (window-pixel-width)
                                  image-width)
                               2))
         ;; adjustments for when mppos outside window
         (xpos (min (- (nth 2 image-displayed-edges)
                       (nth 0 image-displayed-edges))
                    (max 0 (- (car mppos)
                              (max 0 image-left-offset) window-left-offset))))
         (ypos (min (- (nth 3 image-displayed-edges)
                       (nth 1 image-displayed-edges))
                    (max 0 (- (cdr mppos) window-top-offset))))
         (xipos (+ xpos (nth 0 image-displayed-edges)))
         (yipos (+ ypos (nth 1 image-displayed-edges))))
    (cons xipos yipos)))


;; * Copy

(defun edoc-keynav-kill-ring-save (&optional beg end pre)
  "Save the text in the region as if killed, but don’t kill it (aka copy text).

The region text is extracted by slicing a substring between indices BEG and END
(exclusively) out of buffer-local `edoc-keynav-text'. BEG defaults to the
smaller of `edoc-keynav-mark' and `edoc-keynav-point', while END defaults to the
larger.

With a non-nil prefix argument PRE, the region text is instead extracted using
`edoc-info-gettext'. This may work even if there is misalignment between
characters and charlayouts, while the default method works better if
textregions overlap.

Before the copied text is added to the kill ring it is filtered through
`edoc-keynav-copy-filter'. `edoc-keynav-copy-filter-remove-linebreaks' and
`edoc-keynav-copy-filter-add-parbreaks' control what happens there.

For backward compatibility with disconnected regions, if the last command was
`edoc-keynav-mouse-extend-region', the region text is instead extracted by
applying `edoc-info-gettext' to `edoc-view-active-region' like in
`edoc-view-kill-ring-save' but separated by `edoc-keynav-copy-region-separator'.

Unless the region is currently displayed, it is shortly displayed to indicate
the copied text. The display duration can be controlled using
`edoc-keynav-copy-region-blink-delay'. Finally the cursor is displayed."
  (interactive (list nil nil current-prefix-arg))
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))
  (if (memq last-command
	    '(edoc-keynav-mouse-extend-region))
      (let ((txt (edoc-view-active-region-text)))
	(setq edoc-view-active-region nil)
	(kill-new (mapconcat 'edoc-keynav-copy-filter txt
			     edoc-keynav-copy-region-separator)))
    (unless beg
      (setq beg
	    (if (<= edoc-keynav-mark edoc-keynav-point)
		edoc-keynav-mark
	      edoc-keynav-point)))
    (unless end
      (setq end
	    (if (<= edoc-keynav-mark edoc-keynav-point)
		edoc-keynav-point
	      edoc-keynav-mark)))
    (message "pre: %s" pre)
    (if pre
	(kill-new (edoc-keynav-copy-filter
		   (edoc-info-gettext
		    (edoc-view-current-page)
		    (edoc-keynav-get-region-rpos))
		   beg end))
      (kill-new (edoc-keynav-copy-filter
		 (substring edoc-keynav-text beg end)
		 beg end))))
  
  (when (called-interactively-p 'interactive)
    (message "Copied text")
    (if (or (and edoc-keynav-transient-mark-mode
		 edoc-keynav-mark-active-p)
	    (memq last-command
		  '(edoc-keynav-mouse-set-region
		    edoc-keynav-mouse-extend-region)))
	(edoc-keynav-deactivate-mark)
      (when (> edoc-keynav-copy-region-blink-delay 0)
	(edoc-view-display-region
	 (list (edoc-keynav-get-region-rpos)))
	(sit-for edoc-keynav-copy-region-blink-delay))
      (progn
	(when edoc-keynav-pointer-as-cursor-minor-mode
	  (edoc-view-redisplay))
	(edoc-keynav-display-region-cursor)))))


(defun edoc-keynav-copy-filter (txt &optional beg end)
  "Filters text copied by `edoc-keynav-kill-ring-save'.
TXT is the string of text copied. BEG and END are the indices in
`edoc-keynav-charlayout' of its start and end position. Returns the filtered
string which is only then added to the kill ring.

If `edoc-keynav-copy-filter-add-parbreaks', BEG, and END are non-nil an extra
linebreak is inserted at paragraph breaks.

If `edoc-keynav-copy-filter-remove-linebreaks' is non-nil all single linebreaks
are replaced with single spaces.

To add further filters advice this function."
  
  ;; get list of relative indices of paragraph ends within txt
  (if (and edoc-keynav-copy-filter-add-parbreaks beg end)
      (let ((parends (--map (- it beg)
			    (--filter
			     (and (>= it beg) (< it end))
			     edoc-keynav-parends))))
	;; add linebreaks at all parends
	(setq txt
	      (edoc-keynav-insert-string-at-indices "\n" txt parends))))
  
  ;; replace single linebreaks with spaces
  (if edoc-keynav-copy-filter-remove-linebreaks
      (setq txt
	    (replace-regexp-in-string
	     "\\([^\n]\\)\n\\([^\n]\\)" "\\1 \\2" txt))))


(defun edoc-keynav-insert-string-at-indices (ins s is)
  "Insert string INS into string S at indices given in the increasing list IS."
  (let ((i 0))
    (dolist (it is s)
      (let ((beg (substring s 0 (+ it i)))
	    (end (substring s (+ it i))))
	(setq s (concat beg ins end))
	(setq i (+ i (length ins)))))))



;; * Annotate

(defun edoc-keynav-region-to-active-region (&optional _arg)
  "Saves the region to `edoc-view-active-region' unless last command extended it.
This function is used as before advice to `edoc-view-active-region'."
  (unless (memq last-command
		'(edoc-keynav-mouse-extend-region
		  edoc-view-mouse-set-region-rectangle))
    (setq edoc-view-active-region
	  (list (edoc-keynav-get-region-rpos)))))

(defun edoc-keynav-after-markup-advice (&rest _arg)
  "Deactivate region and display cursor."
  (when (equal major-mode 'edoc-view-mode)
    (when edoc-keynav-transient-mark-mode
      (setq edoc-keynav-mark-active-p nil))
    (edoc-keynav-display-region-cursor)))

(defun edoc-keynav-annot-activate (&optional arg)
  "Edit the contents of the annotation or follow the link at point.
With C-u edit contents of the closest text annotation on page.
With C-u C-u edit contents of link instead of following it."
  ;; MAYBE handle case where link and other annotation overlap
  ;; MAYBE refactor
  (interactive "P")
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))  
  (if (equal arg '(4))
      (edoc-annot-edit-contents
       (edoc-keynav-annot-get-closest 'text))
    (let ((a (ignore-errors
               (edoc-annot-at-position
	        (edoc-keynav-point-to-pixel-pos)))))
      (cond ((and a
                  (not (equal arg '(16)))
		  (equal (alist-get 'type a) 'link))
	     (let ((link (edoc-keynav-link-at-point)))
	       (when link
	         (edoc-links-action-perform link))))
	    (a 
	     (edoc-annot-edit-contents a))
            ((null a)
             (message "No annotation here"))))))
	  

(defun edoc-keynav-annot-get-closest (&optional type)
  "Return the annotation on page closest to point.
With TYPE consider only annotations of that type.

Warning: This function does currently not use markup-edges, only edges,
and assumes they represent a rectangle."
  ;; MAYBE implement using markup-edges where applicable
  (let* ((size (edoc-view-image-size))
	 (width (float (car size)))
	 (height (float (cdr size)))
	 (rpos (edoc-keynav-point-to-relative-pos))
	 (annots (edoc-annot-getannots (edoc-view-current-page))))
    (unless annots
      (user-error "No annotations on current page"))
    (when type
	(setq annots
	      (--filter (equal (cdr (assq 'type it)) type) annots))
	(unless annots
	  (user-error "No annotations of type specified on current page")))
    (--min-by (> (edoc-keynav-distance-rectangle-point
		  (cdr (assq 'edges it)) rpos width height)
		 (edoc-keynav-distance-rectangle-point
		  (cdr (assq 'edges other)) rpos width height))
	      annots)))


(defun edoc-keynav-annot-add-text-left (&optional right icon property-alist)
  "Add text annotation to left margin at height of point.
With RIGHT non-nil, add it to right margin. Interactively RIGHT is passed as a
prefix argument. The annotation is activated too.

The y-coordinate of the (top-left corner of the icon of the) annotation is the
y-coordinate of the top-left boundary of the character at `edoc-keynav-point'.
The x-coordinate is the x-coordinate of the left(right)-most textregion
boundary on the page, minus (plus) `edoc-keynav-annot-text-margin' and the icon
width. The x-coordinate is adjusted if the icon would end up outside the page
image.

ICON and PROPERTY-ALIST are passed on to `edoc-annot-add-text-annotation', which
creates the annotation after the right position has been determined."
  (interactive "P")
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))  
  (let ((ypos (cdr (edoc-keynav-point-to-pixel-pos t)))
        (dx-icon (car (edoc-util-scale-points-to-pixel
                       edoc-annot-text-annotation-size 'round)))
        (dx-margin edoc-keynav-annot-text-margin)
        xpos)
    ;; determine a good x-coordinate
    (if right
        ;; then the annotation is placed in the right margin
        (setq xpos
              (min (- (car (edoc-view-image-size)) dx-icon)
                   (+
                    (car (edoc-util-scale-relative-to-pixel
                          (cons 
                           (nth 2
                                (--max-by
                                 (> (nth 2 it) (nth 2 other))
                                 edoc-keynav-textregions))
                           1)))
                    dx-margin)))
      ;; else the annotation is placed in the left margin
      (setq xpos
            (max 0
                 (-
                  (car (edoc-util-scale-relative-to-pixel
                        (cons 
                         (nth 0
                              (--min-by
                               (> (car it) (car other))
                               edoc-keynav-textregions))
                         1)))
                  dx-margin
                  dx-icon))))
    ;; create and activate the annotation
    (edoc-annot-activate-annotation
     (edoc-annot-add-text-annotation (cons xpos ypos)
                                   icon
                                   property-alist))))


(defun edoc-keynav-annot-add-text-right (&optional icon property-alist)
  "Simple wrapper around `edoc-keynav-annot-add-text-left'."
  (interactive)
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))  
  (edoc-keynav-annot-add-text-left t icon property-alist))


(defun edoc-keynav-link-at-point ()
  "Returns the link at point or nil if none found."
  (let* ((links (edoc-cache-pagelinks (edoc-view-current-page)))
	 (rpos (edoc-keynav-point-to-relative-pos)))
    (cl-some
     (lambda (l)
       (and
	(edoc-util-edges-inside-p (cdr (assq 'edges l)) rpos)
	l))
     links)))
  

(defun edoc-keynav-annot-delete (&optional arg)
  "Delete annotation at point.
With single pregix ARG delete text annotation closest to point.
With double prefix ARG delete all annotations in region between mark and point;
in that case annotations of type 'link' are not deleted."
  (interactive "P")
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))  
  (when (and (called-interactively-p 'interactive)
	     edoc-keynav-pointer-as-cursor-minor-mode
	     edoc-keynav-point-from-pointer)
    (edoc-keynav-mouse-set-point-from-pointer))  
  (cond ((null arg)
         (edoc-keynav-annot-delete-at-point))
        ((equal arg '(4))
         (edoc-keynav-annot-delete-closest-text))
        ((equal arg '(16))
         (edoc-keynav-annot-delete-in-region))))


(defun edoc-keynav-annot-delete-at-point ()
  "Delete annotation at point.
Wrapper around `edoc-annot-delete' that passes it the annotation at point using
`edoc-keynav-point-to-pixel-pos'."
  (edoc-annot-delete
   (edoc-annot-at-position
    (edoc-keynav-point-to-pixel-pos)))
  (edoc-keynav-display-region-cursor))


(defun edoc-keynav-annot-delete-closest-text ()
  "Delete text annotation closest to point."
  (edoc-annot-delete
   (edoc-keynav-annot-get-closest 'text))
  (edoc-keynav-display-region-cursor))


(defun edoc-keynav-annot-delete-in-region ()
  "Delete all annotations in region between mark and point.
Annotations of type 'link' are not deleted."
  (let* ((annots
	  (edoc-annot-getannots (edoc-view-current-page)))
	 (annots
	  (--filter (not (equal (cdr (assq 'type it)) 'link))
		    (--filter (edoc-keynav-annot-in-region-p it) annots))))
    ;; MAYBE this redisplays image after each deletion - not optimal
    (mapc 'edoc-annot-delete annots)
    (edoc-keynav-display-region-cursor)))

	  
(defun edoc-keynav-annot-in-region-p (a)
  "Returns non-nil if an annotation A is in region between mark and point."
  (let ((edges (alist-get 'markup-edges a)))
    ;; each line (connected region) is in a separate edgelist (assumed ordered)
    (when edges
      (let* ((rpos-start (cons (nth 0 (nth 0 edges))
			       (nth 1 (nth 0 edges))))
	     (rpos-end (cons (nth 2 (-last-item edges))
			     (nth 3 (-last-item edges))))
	     (ichar-start
	      (edoc-keynav-relative-pos-to-ichar rpos-start))
	     (ichar-end
	      (edoc-keynav-relative-pos-to-ichar rpos-end))
	     (region-start
	      (min edoc-keynav-mark edoc-keynav-point))
	     (region-end
	      (max edoc-keynav-mark edoc-keynav-point)))
	(and (<= region-start ichar-start)
	     (>= region-end ichar-end))))))



;; * Misc

(defun edoc-keynav-get-region-rpos ()
  "Returns the region between mark and point as a list of relative positions.
Returns a list (X1 Y1 X2 Y2) where (X1, Y1) is the relative coordinate of the
left-edge midpoint of the bounding box of the first character in the region and
(X2, Y2) is the corresponding coordinate for the first character after the
region."
  (let* ((mark edoc-keynav-mark)
	 (point edoc-keynav-point)
	 (mark-rpos
	  (edoc-keynav-ichar-to-relative-pos mark))
	 (point-rpos
	  (edoc-keynav-ichar-to-relative-pos point)))
    (if (<= mark point)
	(list (car mark-rpos) (cdr mark-rpos)
	      (car point-rpos) (cdr point-rpos))
      (list (car point-rpos) (cdr point-rpos)
	    (car mark-rpos) (cdr mark-rpos)))))


(defun edoc-keynav-ichar-to-relative-pos (ichar &optional lefttop)
  "Convert index ICHAR to a relative position.
Given ICHAR, an index in `edoc-keynav-charlayout', return the relative image
coordinates of the left-edge midpoint of the corresponding characters bounding
rectangle, (x . y).

With LEFTTOP non-nil return the coordinates of the left top vertex instead."
  (let ((edges (nth 1 (nth ichar edoc-keynav-charlayout))))
    (cons (nth 0 edges)
	  (if lefttop
	      (nth 1 edges)
	    (/ (+ (nth 1 edges) (nth 3 edges)) 2)))))


(defun edoc-keynav-point-to-relative-pos (&optional lefttop)
  "Return point as a relative position.
Return the left-edge midpoint of the bounding box of the character in
`edoc-keynav-charlayout' at index `edoc-keynav-point'.

The returned point is given in relative image coordinates (x . y).

With LEFTTOP non-nil return the coordinates of the left top vertex instead."
  (edoc-keynav-ichar-to-relative-pos edoc-keynav-point lefttop))


(defun edoc-keynav-point-to-pixel-pos (&optional lefttop)
  "Return point as an absolute pixel position.
Return the left-edge midpoint of the bounding box of the character in
`edoc-keynav-charlayout' at index `edoc-keynav-point'.

The returned vertex is given in (absolute) pixel image coordinates (x . y).

With LEFTTOP non-nil return the coordinates of the left top vertex instead."
  (edoc-util-scale-relative-to-pixel
   (edoc-keynav-ichar-to-relative-pos edoc-keynav-point lefttop)))


(defun edoc-keynav-pixel-pos-to-ichar (ppos &optional no-find-closest-char)
  "Convert a pixel position PPOS to an index in `edoc-keynav-charlayout'.
PPOS is a cons (x . y) of pixel image (page) coordinates.

The return value is the index of the character in `edoc-keynav-charlayout' whose
bounding rectangles left-edge midpoint is closest to PPOS.

This function is just the composition of `edoc-util-scale-pixel-to-relative' and
`edoc-keynav-relative-pos-to-ichar'. See the latter for details on
`NO-FIND-CLOSEST-CHAR'."
  (edoc-keynav-relative-pos-to-ichar
   (edoc-util-scale-pixel-to-relative ppos)
   no-find-closest-char))


(defun edoc-keynav-relative-pos-to-ichar (rpos &optional no-find-closest-char)
  "Convert a relative position RPOS to an index in `edoc-keynav-charlayout'.
RPOS is a cons (x . y) of relative image (page) coordinates.

The return value is the index of the character in `edoc-keynav-charlayout' whose
bounding rectangles left-edge midpoint is closest to RPOS.

An attempt is first made to find the right character by looking for a character
directly at RPOS and using it together with its adjacent character. If no
character is found directly at RPOS, and if NO-FIND-CLOSEST-CHAR is non-nil, a
search is made for the character with left-edge midpoint closest to RPOS among
all characters on the current page.

This function is used by commands related to isearch, occur, textregions, mouse
selection, and `edoc-keynav-annot-in-region-p'."
  (let* ((size (edoc-view-image-size))
	 (width (float (car size)))
	 (height (float (cdr size)))
	 (page (edoc-view-current-page))
	 charregion
	 next-charregion
	 ichar)
    (if (setq charregion (nth 1 (nth 0 (edoc-info-charlayout
					page rpos))))
	;; if a charregion is found at rpos
	(progn
	  ;; get its index
	  (setq ichar
		(--find-index
		 (cl-every '= charregion (nth 1 it))
		 edoc-keynav-charlayout))
	  (if (and (> (car rpos)
		      (/ (+ (nth 0 charregion) (nth 2 charregion)) 2))
		   (setq next-charregion
			 (nth 1 (nth (1+ ichar) edoc-keynav-charlayout)))
		   (< (edoc-keynav-distance-midleft-point
		       next-charregion rpos width height)
		      (edoc-keynav-distance-midleft-point
		       charregion rpos width height)))
	      ;; if the right edge is closer to rpos than the left edge,
	      ;; and there exists a charregion after
	      ;; and its left edge midpoint is closer to rpos
	      (setq ichar (1+ ichar))))
      ;; else when no charregion is found at rpos
      (if no-find-closest-char
	  (user-error (concat "No character found at position. "
			      "Try setting no-find-closest-char to nil"))
	;; else find the character with the closest left edge midpoint
	;; MAYBE comparing to all characters on page is unnecessary,
	;;       but fast enough
	(setq charregion
	      (nth 1
		   (--min-by (> (edoc-keynav-distance-midleft-point
				 (nth 1 it) rpos width height)
				(edoc-keynav-distance-midleft-point
				 (nth 1 other) rpos width height))
			     edoc-keynav-charlayout)))
	;; return user-error or the index of the found charregion
	(if (null charregion)
	    (user-error "No character found on page")
	  (setq ichar (--find-index
		       (cl-every '= charregion (nth 1 it))
		       edoc-keynav-charlayout)))))
    ichar))


(defun edoc-keynav-distance-midleft-point (rect point width height)
  "Returns the distance between the left-edge-midpoint of RECT and POINT.

RECT is a list with elements (x1 y1 x2 y2) giving the page-relative coordinates
of two diagonally opposed vertices (left top and right bottom; the origin is at
the top left of the page) of a rectangle.

POINT is a cons (px . py) giving its page-relative coordinates.

WIDTH is the absolute page width and HEIGHT the absolute page height.
It is assumed that the rectangle is aligned with the coordinate axes.
The absolute distance is returned."
  (let* ((mx (nth 0 rect))
	 (y1 (nth 1 rect))
	 (y2 (nth 3 rect))
	 (my (/ (+ y1 y2) 2))
	 (px (car point))
	 (py (cdr point))
	 (dx (- mx px))
	 (dy (- my py)))
    (sqrt (+ (* width width dx dx) (* height height dy dy)))))


(defun edoc-keynav-distance-rectangle-point (rect point width height)
  "Returns the distance between the rectangle RECT and point POINT.

RECT is a list with elements (x1 y1 x2 y2) giving the page-relative coordinates
of two diagonally opposed vertices (left top and right bottom; the origin is at
the top left of the page) of a rectangle.

POINT is a cons (px . py) giving its page-relative coordinates.

WIDTH is the absolute page width and HEIGHT the absolute page height.
It is assumed that the rectangle is aligned with the coordinate axes.
The absolute distance is returned."
  (let* ((x1 (nth 0 rect))
	 (y1 (nth 1 rect))
	 (x2 (nth 2 rect))
	 (y2 (nth 3 rect))
	 (px (car point))
	 (py (cdr point))
	 (dx (max (- x1 px) 0 (- px x2)))
	 (dy (max (- y1 py) 0 (- py y2))))
    (sqrt (+ (* width width dx dx) (* height height dy dy)))))


(defun edoc-keynav-page-align-linebreaks ()
  "Fix misalignment between `edoc-keynav-text' and `edoc-keynav-charlayout'.
Due to a bug in poppler versions 21.03.0-21.07.0 such misalignment used to be
common; with more recent versions this fix should rarely be needed.

Text before each offending linebreak character '\n' is either removed or padded
so that the index of the n'th linebreak character aligns with the index of the
n'th zero-area charlayout rectangle. This only works if no linebreaks are
inserted or dropped in between. Still, unequal numbers of 'linebreaks' are
allowed, with only a warning displayed, since then this correction may still be
helpful if the missing or extra linebreaks occur at the end (all subsequent
text is shifted at each adjustment)."
  (interactive)
  (if edoc-keynav-lazy-load
      (edoc-keynav-lazy-load))
  (let* ((string edoc-keynav-text)
	 (inds (-map #'car (s-matched-positions-all "\n" string)))
	 (ends edoc-keynav-lineends)
	 (nends (length ends))
	 (ninds (length inds))
	 (fill " ")
	 (j 0)
	 i
	 e
	 nfill
	 nomit)
    (unless (equal inds ends)
      (message "Misalignment of line breaks found. Attempting a fix.")
      (message "Indices of linebreaks in edoc-keynav-text:\n%s" inds)
      (message "Indices of linebreaks in edoc-keynav-charlayout:\n%s" ends)
      (unless (equal ninds nends)
	(display-warning :warning
			 (concat "Unequal numbers of linebreaks. This fix "
				 "will only be helpful if the missing "
				 "linebreaks occur at the end.")))
      (while (< j (min ninds nends))
	(setq i (nth j inds))
	(setq e (nth j ends))
	(unless (equal i e)
	  (if (> e i)
	      (progn
		;; calculate number of characters to fill
		(setq nfill (- e i))
		;; create the filled string
		(setq string (s-concat (substring string 0 i)
				       (s-repeat nfill fill)
				       (substring string i))))
	    (progn
	      ;; calculate number of characters to omit
	      (setq nomit (- i e))
	      (setq string (s-concat (substring string 0 (- i nomit))
				     (substring string i))))
	    ;; need to recalculate inds at each iteration
	    (setq inds (-map #'car (s-matched-positions-all "\n" string)))))
	(setq j (1+ j)))
      (setq edoc-keynav-text string))))


(provide 'edoc-keynav)
;;; edoc-keynav.el ends here
