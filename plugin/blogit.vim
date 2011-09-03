"""
" Copyright (C) 2009-2010 Romain Bignon
"
" This program is free software; you can redistribute it and/or modify
" it under the terms of the GNU General Public License as published by
" the Free Software Foundation, version 3 of the License.
"
" This program is distributed in the hope that it will be useful,
" but WITHOUT ANY WARRANTY; without even the implied warranty of
" MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
" GNU General Public License for more details.
"
" You should have received a copy of the GNU General Public License
" along with this program; if not, write to the Free Software
" Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
"
" Maintainer:   Romain Bignon
" Contributor:  Adam Schmalhofer
" URL:          http://symlink.me/wiki/blogit
" Version:      1.4.3
" Last Change:  2010 January 01


runtime! passwords.vim
command! -bang -nargs=* Blogit exec('py blogit.get_command("<bang>", <f-args>)')

let s:used_categories = []
let s:used_tags = []

function! BlogItComplete(findstart, base)
    " based on code from :he complete-functions
    if a:findstart
        " locate the start of the word
        let line = getline('.')
        let start = col('.') - 1
        while start > 0 && line[start - 1] =~ '\S'
            let start -= 1
        endwhile
        return start
    else
        let sep = ', '
        if getline('.') =~# '^Categories: '
            let L = s:used_categories
        elseif getline('.') =~# '^Tags: '
            let L = s:used_tags
        elseif getline('.') =~# '^Status: ' && exists('b:blog_post_type')
            if b:blog_post_type == 'comments'
                let L = [ 'approve', 'spam', 'hold', 'new', 'rm' ]
            elseif b:blog_post_type == 'post'
                let L = [ 'draft', 'publish', 'private', 'pending', 'new', 'rm' ]
            else
                let L = [ ]
            endif
            let sep = ''
        else
            return []
        endif
        let res = []
        for m in L
            if m =~ '^' . a:base
                call add(res, m . sep)
            endif
        endfor
        return res
    endif
endfunction

function! BlogItCommentsFoldText()
    let line_no = v:foldstart
    if v:foldlevel > 1
        while getline(line_no) !~ '^\s*$'
            let line_no += 1
        endwhile
        let title = getline(line_no + 1)
    else
        let title = substitute(getline(line_no + 1), '^ *', '', '')
    endif
    return '+' . v:folddashes . title
endfunction

python << EOF
import os, vim

# Get the blogit in python module path
for p in vim.eval('&runtimepath').split(','):
    sys.path.append(os.path.join(p, 'plugin'))

sys.path.append(os.path.join(os.getcwd(), 'plugin'))

from blogit import core
blogit = core.BlogIt()

EOF
