"""
" Copyright (C) 2009 Romain Bignon
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
" Version:      1.3
" Last Change:  2009 August 16
"
" Commands :
" ":Blogit ls"
"   Lists all articles in the blog
" ":Blogit new"
"   Opens page to write new article
" ":Blogit this"
"   Make current buffer a blog post
" ":Blogit edit <id>"
"   Opens the article <id> for edition
" ":Blogit commit"
"   Saves the article to the blog
" ":Blogit push"
"   Publish article
" ":Blogit unpush"
"   Unpublish article
" ":Blogit rm <id>"
"   Remove an article
" ":Blogit tags"
"   Show tags and categories list
" ":Blogit preview"
"   Preview current post locally
" ":Blogit help"
"   Display help
"
" Note that preview might not word on all platforms. This is because we have
" to rely on unsupported and non-portable functionality from the python
" standard library.
"
"
" Configuration :
"   Create a file called passwords.vim somewhere in your 'runtimepath'
"   (preferred location is "~/.vim/"). Don't forget to set the permissions so
"   only you can read it. This file should include:
"
"       let blogit_username='Your blog user name'
"       let blogit_password='Your blog password. Not the API-key.'
"       let blogit_url='https://your.path.to/xmlrpc.php'
"
"   In addition you can set these settings in your vimrc:
"
"       let blogit_unformat='pandoc --from=html --to=rst --reference-links'
"       let blogit_format='pandoc --from=rst --to=html --no-wrap'
"
"   The blogit_format and blogit_unformat each contain a shell command to
"   filter the blog entry text (no meta data) before a commit and after an
"   edit, respectively. In the example we use pandoc[1] to edit the blog in
"   reStructuredText[2].
"
"   If you have multible blogs replace 'blogit' in 'blogit_username' etc. by a
"   name of your choice (e.g. 'your_blog_name') and use:
"
"       let blog_name='your_blog_name'
"   or
"       let b:blog_name='your_blog_name'
"
"   to switch between them.
"
" Usage :
"   Just fill in the blanks, do not modify the highlighted parts and everything
"   should be ok.
"
"   gf or <enter> in the ':Blogit ls' buffer edits the blog post in the
"   current line.
"
"   Categories and tags can be omni completed via *compl-function* (usually
"   CTRL-X_CTRL-U). The list of them is gotten automatically on first
"   ":Blogit edit" and can be updated with ":Blogit tags".
"
"   To use tags your WordPress needs to have the UTW-RPC[3] plugin installed
"   (WordPress.com does).
"
" [1] http://johnmacfarlane.net/pandoc/
" [2] http://docutils.sourceforge.net/docs/ref/rst/introduction.html
" [3] http://blog.circlesixdesign.com/download/utw-rpc-autotag/
"
" vim: set et softtabstop=4 cinoptions=4 shiftwidth=4 ts=4 ai

runtime! passwords.vim
command! -nargs=* Blogit exec('py blogit.command(<f-args>)')

let s:used_categories = []
let s:used_tags = []

function! BlogitComplete(findstart, base)
    " based on code from :he complete-functions
    if a:findstart
        " locate the start of the word
        let line = getline('.')
        let start = col('.') - 1
        while start > 0 && line[start - 1] =~ '\a'
            let start -= 1
        endwhile
        return start
    else
        let sep = ', '
        if getline('.') =~# '^Categories: '
            let L = s:used_categories
        elseif getline('.') =~# '^Tags: '
            let L = s:used_tags
        elseif getline('.') =~# '^Status: '
            " for comments
            let L = [ 'approve', 'spam', 'hold', 'new', 'rm' ]
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

function! CommentsFoldText()
    let line_no = v:foldstart
    if v:foldlevel > 1
        while getline(line_no) !~ '^\s*$'
            let line_no += 1
        endwhile
    endif
    return '+' . v:folddashes . getline(line_no + 1)
endfunction

python <<EOF
# -*- coding: utf-8 -*-
# Lets the python unit test ignore eveything above this line (docstring). """
import xmlrpclib, sys, re
from time import mktime, strptime, strftime, localtime, gmtime
from locale import getpreferredencoding
from calendar import timegm
from subprocess import Popen, CalledProcessError, PIPE
from xmlrpclib import DateTime, Fault, MultiCall
from inspect import getargspec
import webbrowser, tempfile

try:
    import vim
except ImportError:
    # Used outside of vim (for testing)
    from minimock import Mock, mock
    import minimock, doctest
    from mock_vim import vim
else:
    doctest = False

#####################
# Do not edit below #
#####################

class BlogIt(object):
    class BlogItException(Exception):
        pass


    class NoPostException(BlogItException):
        pass


    class FilterException(BlogItException):
        def __init__(self, message, input_text, filter):
            self.message = "Blogit: Error happend while filtering with:" + \
                    filter + '\n' + message
            self.input_text = input_text
            self.filter = filter


    class VimVars(object):
        @property
        def blog_username(self):
            return self.vim_variable('username')

        @property
        def blog_password(self):
            return self.vim_variable('password')

        @property
        def blog_url(self):
            """
            >>> mock('vim.eval',
            ...      returns_iter=[ '0', '0', '1', 'http://example.com/' ])
            >>> BlogIt.VimVars().blog_url
            Called vim.eval("exists('b:blog_name')")
            Called vim.eval("exists('blog_name')")
            Called vim.eval("exists('blogit_url')")
            Called vim.eval('blogit_url')
            'http://example.com/'
            >>> minimock.restore()
            """
            return self.vim_variable('url')

        @property
        def blog_postsource(self):
            """ Bool: Include unformated version of a post in an html comment.

            If the program only converts to html, you can have blogit save the
            "source" in an html comment (Warning: This doesn't work reliably
            with Wordpress. Use at your own risk).

                let blogit_postsource=1
            """
            return self.vim_variable('postsource') == '1'

        @property
        def blog_name(self):
            for var_name in ( 'b:blog_name', 'blog_name' ):
                var_value = self.vim_variable(var_name, prefix=False)
                if var_value is not None:
                    return var_value
            return 'blogit'

        def vim_variable(self, var_name, prefix=True):
            """ Simplefy access to vim-variables. """
            if prefix:
                var_name = '_'.join(( self.blog_name, var_name ))
            if vim.eval("exists('%s')" % var_name) == '1':
                return vim.eval('%s' % var_name)
            else:
                return None


    class NoPost(object):
        BLOG_POST_ID = ''

        def __init__(self):
            self.vim_vars = BlogIt.VimVars()

        @property
        def client(self):
            return xmlrpclib.ServerProxy(self.vim_vars.blog_url)

        def read_post(self, *a, **d):
            raise BlogIt.NoPostException

        def send(self, *a, **d):
            raise BlogIt.NoPostException


    class AbstractPost(object):
        def __init__(self, post_data={}, meta_data_dict={},
                     meta_data_f_dict={}, headers=[], post_body=''):
            self.post_data = post_data
            self.meta_data_dict = meta_data_dict
            self.meta_data_f_dict = meta_data_f_dict
            self.HEADERS = headers
            self.POST_BODY = post_body

        def read_header(self, line):
            """ XXX: Previously called getMeta().
            Reads the meta-data in the current buffer. Outputed as dictionary.

            >>> blogit.AbstractPost().read_header('tag: value')
            ('tag', 'value')
            """
            r = re.compile('^(.*?): (.*)$')
            m = r.match(line)
            return m.group(1, 2)

        def read_body(self, lines):
            """ XXX: Previously called getText(). """
            return '\n'.join(lines).strip()

        def read_post(self, lines):
            r""" XXX: Previously called read_comments().
            Yields a dict for each comment in the current buffer.

            >>> BlogIt.AbstractPost(post_body='content').read_post(
            ...         [ 'Tag:  Value  ', '', 'Some Text', 'in two lines.' ])
            {'content': 'Some Text\nin two lines.', 'Tag': 'Value'}
            """
            d = {self.POST_BODY: ''}
            for i, line in enumerate(lines):
                if line.strip() == '':
                    d[self.POST_BODY] = self.read_body(lines[i+1:])
                    break
                t, v = self.read_header(line)
                if not t.startswith('blogit_'):
                    d[t] = v.strip()
            return d

        def display(self):
            for label in self.HEADERS:
                yield self.format_header(label)
            yield ''
            for line in self.format_body():
                yield line

        def format_header(self, label):
            """
            Returns a header line formated as it will be displayed to the user.

            >>> blogit.AbstractPost().format_header('A')
            'A: '
            >>> blogit.AbstractPost(meta_data_dict={'A': 'a'}
            ...     ).format_header('A')
            'A: '
            >>> blogit.AbstractPost(post_data={'b': 'two'},
            ...     meta_data_dict={'A': 'a'}).format_header('A')
            'A: '
            >>> blogit.AbstractPost(post_data={'a': 'one', 'b': 'two'},
            ...     meta_data_dict={'A': 'a'}).format_header('A')
            'A: one'
            >>> blogit.AbstractPost(post_data={'a': 'onE'},
            ...     meta_data_dict={'A': 'a'},
            ...     meta_data_f_dict={'A': lambda x: x.swapcase()}
            ...     ).format_header('A')
            'A: ONe'
            """
            try:
                val = self.post_data[self.meta_data_dict[label]]
            except KeyError:
                val = ''
            if label in self.meta_data_f_dict:
                val = self.meta_data_f_dict[label](val)
            return '%s: %s' % ( label, unicode(val).encode('utf-8') )


    class BlogPost(AbstractPost):
        def __init__(self, blog_post_id, post_data={}, meta_data_dict=None,
                     meta_data_f_dict=None, headers=None,
                     post_body='description', vim_vars=None):
            if meta_data_dict is None:
                meta_data_dict = {'From': 'wp_author_display_name',
                                  'Post-Id': 'postid',
                                  'Subject': 'title',
                                  'Categories': 'categories',
                                  'Tags': 'mt_keywords',
                                  'Date': 'date_created_gmt',
                                  'Status': 'blogit_status',
                                 }
            if meta_data_f_dict is None:
                def split_comma(x): return x.split(', ')
                meta_data_f_dict = { 'Date': BlogIt.DateTime_to_str,
                           'Categories': lambda L: ', '.join(L),
                           'Status': self._display_comment_count
                         }
            if headers is None:
                headers = ['From', 'Post-Id', 'Subject', 'Status',
                           'Categories', 'Tags', 'Date' ]
            if vim_vars is None:
                vim_vars = BlogIt.VimVars()
            super(BlogIt.BlogPost, self).__init__(post_data, meta_data_dict,
                     meta_data_f_dict, headers, post_body)
            self.vim_vars = vim_vars
            self.BLOG_POST_ID = blog_post_id

        @staticmethod
        def _display_comment_count(d):
            if d == '':
                return u'new'
            comment_typ_count = [ '%s %s' % (d[key], text)
                    for key, text in ( ( 'awaiting_moderation', 'awaiting' ),
                            ( 'spam', 'spam' ) )
                    if d[key] > 0 ]
            if comment_typ_count == []:
                s = u''
            else:
                s = u' (%s)' % ', '.join(comment_typ_count)
            return ( u'%(post_status)s \u2013 %(total_comments)s Comments'
                    + s ) % d

        @classmethod
        def create_new_post(cls, body_lines=['']):
            b = cls('')
            b.post_data.update({'post_status': 'draft', 'description': '',
                    'wp_author_display_name': b.vim_vars.blog_username})
            b.init_vim_buffer()
            vim.current.buffer[-1:] = body_lines
            return b

        def init_vim_buffer(self):
            BlogIt.display(self)
            vim.command('nnoremap <buffer> gf :py blogit.list_comments()<cr>')
            vim.command('setlocal nomodified ft=mail textwidth=0 ' +
                                 'completefunc=BlogitComplete')
            vim.current.window.cursor = (8, 0)

        def read_body(self, lines):
            r"""

            Can raise FilterException.

            >>> mock('vim.mocked_eval')

            >>> blogit.BlogPost(42).read_body([ 'one', 'two', 'tree', 'four' ])
            Called vim.mocked_eval("exists('blogit_format')")
            Called vim.mocked_eval("exists('blogit_postsource')")
            ['one\ntwo\ntree\nfour']

            >>> mock('vim.mocked_eval', returns_iter=['1', 'sort', '0'])
            >>> blogit.BlogPost(42).read_body([ 'one', 'two', 'tree', 'four' ])
            Called vim.mocked_eval("exists('blogit_format')")
            Called vim.mocked_eval('blogit_format')
            Called vim.mocked_eval("exists('blogit_postsource')")
            ['four\none\ntree\ntwo\n']

            >>> mock('vim.mocked_eval', returns_iter=['1', 'false'])
            >>> blogit.BlogPost(42).read_body([ 'one', 'two', 'tree', 'four' ])
            Traceback (most recent call last):
                ...
            FilterException

            >>> minimock.restore()
            """
            text = super(BlogIt.BlogPost, self).read_body(lines)
            return map(self.format, text.split('\n<!--more-->\n\n'))

        def unformat(self, text):
            r"""
            >>> mock('vim.mocked_eval', returns_iter=[ '1', 'false' ])
            >>> mock('sys.stderr')
            >>> BlogIt.BlogPost(42).unformat('some random text')
            ...         #doctest: +NORMALIZE_WHITESPACE
            Called vim.mocked_eval("exists('blogit_unformat')")
            Called vim.mocked_eval('blogit_unformat')
            Called sys.stderr.write('Blogit: Error happend while filtering
                    with:false\n')
            'some random text'

            >>> BlogIt.BlogPost(42).unformat('''\n\n \n
            ...         <!--blogit-- Post Source --blogit--> <h1>HTML</h1>''')
            'Post Source'

            >>> minimock.restore()
            """
            if text.lstrip().startswith('<!--blogit-- '):
                return ( text.replace('<!--blogit--', '', 1).
                        split(' --blogit-->', 1)[0].strip() )
            try:
                return self.filter(text, 'unformat')
            except BlogIt.FilterException, e:
                sys.stderr.write(e.message)
                return e.input_text

        def format(self, text):
            formated = self.filter(text, 'format')
            if self.vim_vars.blog_postsource:
                formated = "<!--blogit--\n%s\n--blogit-->\n%s" % ( text, formated )
            return formated

        def filter(self, text, vim_var='format'):
            r""" Filter text with command in vim_var.

            Can raise FilterException.

            >>> mock('vim.mocked_eval')
            >>> BlogIt.BlogPost(42).filter('some random text')
            Called vim.mocked_eval("exists('blogit_format')")
            'some random text'

            >>> mock('vim.mocked_eval', returns_iter=[ '1', 'false' ])
            >>> BlogIt.BlogPost(42).filter('some random text')
            Traceback (most recent call last):
                ...
            FilterException

            >>> mock('vim.mocked_eval', returns_iter=[ '1', 'rev' ])
            >>> BlogIt.BlogPost(42).filter('')
            Called vim.mocked_eval("exists('blogit_format')")
            Called vim.mocked_eval('blogit_format')
            ''

            >>> mock('vim.mocked_eval', returns_iter=[ '1', 'rev' ])
            >>> BlogIt.BlogPost(42).filter('some random text')
            Called vim.mocked_eval("exists('blogit_format')")
            Called vim.mocked_eval('blogit_format')
            'txet modnar emos\n'

            >>> mock('vim.mocked_eval', returns_iter=[ '1', 'rev' ])
            >>> BlogIt.BlogPost(42).filter(
            ...         'some random text\nwith a second line')
            Called vim.mocked_eval("exists('blogit_format')")
            Called vim.mocked_eval('blogit_format')
            'txet modnar emos\nenil dnoces a htiw\n'

            >>> minimock.restore()

            """
            filter = self.vim_vars.vim_variable(vim_var)
            if filter is None:
                return text
            try:
                p = Popen(filter, shell=True, stdin=PIPE, stdout=PIPE, stderr=PIPE)
                p.stdin.write(text.encode(getpreferredencoding()))
                p.stdin.close()
                if p.wait():
                    raise BlogIt.FilterException(p.stderr.read(), text, filter)
                return p.stdout.read().decode(getpreferredencoding()
                                             ).encode('utf-8')
            except BlogIt.FilterException:
                raise
            except Exception, e:
                raise BlogIt.FilterException(e.message, text, filter)

        def format_body(self):
            """
            Yields the lines of a post body.
            """
            content = self.unformat(self.post_data.get(self.POST_BODY, ''))
            for line in content.splitlines():
                yield line

            if self.post_data.get('mt_text_more'):
                yield ''
                yield '<!--more-->'
                yield ''
                content = self.unformat(self.post_data["mt_text_more"])
                for line in content.splitlines():
                    yield line


    class WordPressBlogPost(BlogPost):
        def __init__(self, blog_post_id, post_data={}, meta_data_dict=None,
                     meta_data_f_dict=None, headers=None,
                     post_body='description', vim_vars=None, client=None):
            super(BlogIt.WordPressBlogPost, self
                 ).__init__(blog_post_id, post_data, meta_data_dict,
                            meta_data_f_dict, headers, post_body, vim_vars)
            if client is None:
                client = xmlrpclib.ServerProxy(self.vim_vars.blog_url)
            self.client = client

        def send(self, lines, push=None):
            """ Send current post to server.

            >>> mock('sys.stderr')
            >>> p = BlogIt.WordPressBlogPost(42,
            ...         {'post_status': 'new', 'postid': 42})
            >>> mock('p.client'); mock('p.getPost'); mock('p.display')
            >>> p.send([])    #doctest: +NORMALIZE_WHITESPACE
            Called p.client.metaWeblog.editPost( 42, 'user', 'password',
                    {'post_status': 'new', 'postid': 42, 'description': ''}, 0)
            Called p.getPost()
            >>> minimock.restore()
            """

            def sendPost(push):
                """ Unify newPost and editPost from the metaWeblog API. """
                if self.BLOG_POST_ID == '':
                    self.BLOG_POST_ID = self.client.metaWeblog.newPost('',
                            self.vim_vars.blog_username,
                            self.vim_vars.blog_password, self.post_data, push)
                else:
                    self.client.metaWeblog.editPost(self.BLOG_POST_ID,
                            self.vim_vars.blog_username,
                            self.vim_vars.blog_password, self.post_data, push)

            def date_from_meta(str_date):
                if push is None and self.current_post['post_status'] == 'publish':
                    return BlogIt.str_to_DateTime(str_date)
                return BlogIt.str_to_DateTime()

            self.meta_data_f_dict['Date'] = date_from_meta

            self.post_data.update(self.read_post(lines))
            push_dict = { 0: 'draft', 1: 'publish',
                          None: self.post_data['post_status'] }
            self.post_data['post_status'] = push_dict[push]
            if push is None:
                push = 0
            try:
                sendPost(push)
            except Fault, e:
                sys.stderr.write(e.faultString)
            self.getPost()

        def getPost(self):
            """
            >>> mock('xmlrpclib.MultiCall', returns=Mock(
            ...         'multicall', returns=[{'post_status': 'draft'}, {}]))
            >>> mock('vim.mocked_eval')

            >>> p = BlogIt.WordPressBlogPost(42)
            >>> p.getPost()
            Called xmlrpclib.MultiCall(<ServerProxy for example.com/RPC2>)
            Called multicall.metaWeblog.getPost(42, 'user', 'password')
            Called multicall.wp.getCommentCount('', 'user', 'password', 42)
            Called vim.mocked_eval('s:used_tags == [] || s:used_categories == []')
            Called multicall()
            >>> sorted(p.post_data.items())    #doctest: +NORMALIZE_WHITESPACE
            [('blogit_status', {'post_status': 'draft'}),
             ('post_status', 'draft')]
            >>> minimock.restore()

            """
            username = self.vim_vars.blog_username
            password = self.vim_vars.blog_password

            multicall = xmlrpclib.MultiCall(self.client)
            multicall.metaWeblog.getPost(self.BLOG_POST_ID, username, password)
            multicall.wp.getCommentCount('', username, password,
                                         self.BLOG_POST_ID)
            if vim.eval('s:used_tags == [] || s:used_categories == []') == '1':
                multicall.wp.getCategories('', username, password)
                multicall.wp.getTags('', username, password)
                d, comments, categories, tags = tuple(multicall())
                vim.command('let s:used_tags = %s' % [ tag['name']
                        for tag in tags ])
                vim.command('let s:used_categories = %s' % [ cat['categoryName']
                        for cat in categories ])
            else:
                d, comments = tuple(multicall())
            comments['post_status'] = d['post_status']
            d['blogit_status'] = comments
            self.post_data = d


    class Comment(AbstractPost):
        def __init__(self, post_data={}, meta_data_dict=None,
                     meta_data_f_dict=None, headers=None, post_body='content'):
            if meta_data_f_dict is None:
                meta_data_f_dict = { 'Date': BlogIt.DateTime_to_str }
            if meta_data_dict is None:
                meta_data_dict = { 'Status': 'status', 'Author': 'author',
                        'ID': 'comment_id', 'Parent': 'parent',
                        'Date': 'date_created_gmt', 'Type': 'type',
                        'content': 'content',
                        }
            if headers is None:
                headers = ['Status', 'Author', 'ID',
                           'Parent', 'Date', 'Type',]
            super(BlogIt.Comment, self).__init__(post_data, meta_data_dict,
                     meta_data_f_dict, headers, post_body)

        def format_body(self):
            """
            Yields the lines of a post body.
            """
            content = self.post_data.get(self.POST_BODY, '')
            for line in content.split('\n'):
                # not splitlines to preserve \r\n in comments.
                yield line


    class CommentList(Comment):
        def __init__(self, meta_data_dict=None,
                     meta_data_f_dict=None, headers=None, post_body='content'):
            super(BlogIt.CommentList, self).__init__({}, meta_data_dict,
                     meta_data_f_dict, headers, post_body)
            self.empty_comment_list()

        def empty_comment_list(self):
            self.comment_list = {}
            self.comments_by_category = {}
            self.add_comment('new', {'status': 'new', 'author': '',
                                     'comment_id': '', 'parent': '0',
                                     'date_created_gmt': '', 'type': '',
                                     'content': ''
                                    })

        def add_comment(self, category, comment_dict):
            """ Callee must garanty that no comment with same id is in list.

            >>> cl = BlogIt.CommentList()
            >>> cl.add_comment('hold', {'comment_id': '1',
            ...                         'content': 'Some Text',
            ...                         'status': 'hold'})
            >>> [ (id, c.post_data) for id, c in cl.comment_list.iteritems()
            ... ]    #doctest: +NORMALIZE_WHITESPACE
            [('', {'status': 'new', 'parent': '0', 'author': '',
              'comment_id': '', 'date_created_gmt': '', 'content': '',
              'type': ''}),
             ('1',
             {'content': 'Some Text', 'status': 'hold', 'comment_id': '1'})]
            >>> [ (cat, [ c.post_data['comment_id'] for c in L ])
            ...         for cat, L in cl.comments_by_category.iteritems()
            ... ]    #doctest: +NORMALIZE_WHITESPACE
            [('new', ['']), ('hold', ['1'])]
            >>> cl.add_comment('spam', {'comment_id': '1'}
            ...               )    #doctest: +ELLIPSIS
            Traceback (most recent call last):
                ...
                assert not comment_dict['comment_id'] in self.comment_list
            AssertionError
            """
            comment = BlogIt.Comment(comment_dict, self.meta_data_dict,
                                     self.meta_data_f_dict,
                                     self.HEADERS, self.POST_BODY)
            assert not comment_dict['comment_id'] in self.comment_list
            self.comment_list[comment_dict['comment_id']] = comment
            try:
                self.comments_by_category[category].append(comment)
            except KeyError:
                self.comments_by_category[category] = [ comment ]

        def display(self):
            """
            # was: append_comment_to_buffer()
            # XXX regression: Order of different statuses.

            >>> list(BlogIt.CommentList().display())    #doctest: +NORMALIZE_WHITESPACE
            ['======================================================================== {{{1',
             '     New',
             '======================================================================== {{{2',
             'Status: new',
             'Author: ',
             'ID: ',
             'Parent: 0',
             'Date: ',
             'Type: ',
             '',
             '',
             '']
            """
            for heading, comments in self.comments_by_category.iteritems():
                if comments == []:
                    continue

                yield 72 * '=' + ' {{{1'
                yield 5 * ' ' + heading.capitalize()

                fold_levels = {}
                for comment in reversed(comments):
                    try:
                        fold = fold_levels[comment.post_data['parent']] + 2
                    except KeyError:
                        fold = 2
                    fold_levels[comment.post_data['comment_id']] = fold
                    yield 72 * '=' + ' {{{%s' % fold
                    for line in comment.display():
                        yield line
                    yield ''

        def changed_comments(self, lines):
            """ Yields comments with changes made to in the vim buffer.

            >>> c = BlogIt.CommentList()
            >>> for comment_dict in [
            ...         {'comment_id': '1', 'content': 'Old Text',
            ...          'status': 'hold', 'unknown': 'tag'},
            ...         {'comment_id': '2', 'content': 'Same Text',
            ...          'Date': 'old', 'status': 'hold'},
            ...         {'comment_id': '3', 'content': 'Same Again',
            ...          'status': 'hold'}]:
            ...     c.add_comment('', comment_dict)
            >>> list(c.changed_comments([
            ...     60 * '=', 'ID: 1 ', 'Status: hold', '', 'Changed Text',
            ...     60 * '=', 'ID:  ', 'Status: hold', '', 'New Text',
            ...     60 * '=', 'ID: 2', 'Status: hold', 'Date: new', '',
            ...             'Same Text',
            ...     60 * '=', 'ID: 3', 'Status: spam', '', 'Same Again',
            ... ]))      #doctest: +NORMALIZE_WHITESPACE
            [{'content': 'Changed Text', 'status': 'hold', 'comment_id': '1',
              'unknown': 'tag'},
             {'status': 'hold', 'content': 'New Text', 'parent': '0',
              'author': '', 'type': '', 'comment_id': '',
              'date_created_gmt': ''},
             {'content': 'Same Again', 'status': 'spam', 'comment_id': '3'}]
            """
            ignored_tags = set([ 'ID', 'Date' ])

            for comment in self.read_post(lines):
                original_comment = self.comment_list[comment['ID']].post_data
                updated_comment = original_comment.copy()
                for t in comment.keys():
                    if t in ignored_tags:
                        continue
                    updated_comment[self.meta_data_dict[t]] = comment[t]
                if original_comment != updated_comment:
                    yield updated_comment

        def read_post(self, lines):
            r""" XXX: Previously call read_comments().
            Yields a dict for each comment in the current buffer.

            >>> list(BlogIt.CommentList().read_post([
            ...     60 * '=', 'Tag2: Val2 ', '',
            ...     60 * '=',
            ...     'Tag:  Value  ', '', 'Some Text', 'in two lines.   ',
            ... ]))    #doctest: +NORMALIZE_WHITESPACE
            [{'content': '', 'Tag2': 'Val2'},
             {'content': 'Some Text\nin two lines.', 'Tag': 'Value'}]
            >>> list(BlogIt.CommentList().read_post([
            ...     60 * '=', 'ID: 1 ', 'Status: hold', '', 'Text',
            ...     60 * '=', 'ID:  ', 'Status: hold', '', 'Text',
            ...     60 * '=', 'ID: 2', 'Status: hold', 'Date: new', '', 'Text',
            ...     60 * '=', 'ID: 3', 'Status: spam', '', 'Text',
            ... ]))      #doctest: +NORMALIZE_WHITESPACE
            [{'content': 'Text', 'Status': 'hold', 'ID': '1'},
             {'content': 'Text', 'Status': 'hold', 'ID': ''},
             {'content': 'Text', 'Status': 'hold', 'ID': '2', 'Date': 'new'},
             {'content': 'Text', 'Status': 'spam', 'ID': '3'}]
            """
            j = 0
            lines = list(lines)
            for i, line in enumerate(lines):
                if line.startswith(60 * '='):
                    if i-j > 1:
                        yield super(BlogIt.CommentList, self).read_post(
                                lines[j:i])
                    j = i + 1
            yield super(BlogIt.CommentList, self).read_post(lines[j:])


    class WordPressCommentList(CommentList):
        def __init__(self, blog_post_id, meta_data_dict=None,
                     meta_data_f_dict=None, headers=None, post_body='content',
                     vim_vars=None, client=None):
            super(BlogIt.WordPressCommentList, self).__init__(
                    meta_data_dict, meta_data_f_dict, headers, post_body)
            if vim_vars is None:
                vim_vars = BlogIt.VimVars()
            self.vim_vars = vim_vars
            if client is None:
                client = xmlrpclib.ServerProxy(self.vim_vars.blog_url)
            self.client = client
            self.BLOG_POST_ID = blog_post_id

        def send(self, lines):
            """ Send changed and new comments to server.

            >>> c = BlogIt.WordPressCommentList(42)
            >>> mock('sys.stderr')
            >>> mock('c.getComments')
            >>> mock('c.changed_comments',
            ...         returns=[ { 'status': 'new', 'content': 'New Text' },
            ...             { 'status': 'will fail', 'comment_id': 13 },
            ...             { 'status': 'will succeed', 'comment_id': 7 },
            ...             { 'status': 'rm', 'comment_id': 100 } ])
            >>> mock('xmlrpclib.MultiCall', returns=Mock(
            ...         'multicall', returns=[ 200, False, True, True ]))
            >>> c.send(None)    #doctest: +NORMALIZE_WHITESPACE
            Called xmlrpclib.MultiCall(<ServerProxy for example.com/RPC2>)
            Called c.changed_comments(None)
            Called multicall.wp.newComment(
                '', 'user', 'password', 42,
                {'status': 'approve', 'content': 'New Text'})
            Called multicall.wp.editComment(
                '', 'user', 'password', 13, {'status': 'will fail'})
            Called multicall.wp.editComment(
                '', 'user', 'password', 7, {'status': 'will succeed'})
            Called multicall.wp.deleteComment('', 'user', 'password', 100)
            Called multicall()
            Called sys.stderr.write('Server refuses update to 13.')
            Called c.getComments()

            >>> vim.current.buffer.change_buffer()
            >>> minimock.restore()

            """
            multicall = xmlrpclib.MultiCall(self.client)
            username, password = self.vim_vars.blog_username, self.vim_vars.blog_password
            multicall_log = []
            for comment in self.changed_comments(lines):
                if comment['status'] == 'new':
                    comment['status'] = 'approve'
                    multicall.wp.newComment(
                            '', username, password, self.BLOG_POST_ID, comment)
                    multicall_log.append('new')
                elif comment['status'] == 'rm':
                    multicall.wp.deleteComment(
                            '', username, password, comment['comment_id'])
                else:
                    comment_id = comment['comment_id']
                    del comment['comment_id']
                    multicall.wp.editComment(
                            '', username, password, comment_id, comment)
                    multicall_log.append(comment_id)
            for accepted, comment_id in zip(multicall(), multicall_log):
                if comment_id != 'new' and not accepted:
                    sys.stderr.write('Server refuses update to %s.' % comment_id)
            return self.getComments()

        def getComments(self, offset=0):
            """ Lists the comments to a post with given id in a new buffer.

            >>> mock('xmlrpclib.MultiCall', returns=Mock(
            ...         'multicall', returns=[], tracker=None))
            >>> mock('vim.command')
            >>> c = BlogIt.WordPressCommentList(42)
            >>> mock('c.display', returns=[])
            >>> mock('c.changed_comments', returns=[])
            >>> c.getComments()   #doctest: +NORMALIZE_WHITESPACE
            Called xmlrpclib.MultiCall(<ServerProxy for example.com/RPC2>)
            Called vim.command(
                'setlocal nomodified linebreak
                          foldmethod=marker foldtext=CommentsFoldText()
                          completefunc=BlogitComplete')
            Called c.display()
            Called c.changed_comments([])

            >>> minimock.restore()
            """
            multicall = xmlrpclib.MultiCall(self.client)
            for comment_typ in ( 'hold', 'spam', 'approve' ):
                multicall.wp.getComments('', self.vim_vars.blog_username,
                        self.vim_vars.blog_password,
                        { 'post_id': self.BLOG_POST_ID, 'status': comment_typ,
                          'offset': offset, 'number': 1000 })
            self.empty_comment_list()
            for comments, heading in zip(multicall(),
                    ( 'In Moderadation', 'Spam', 'Published' )):
                for comment_dict in comments:
                    self.add_comment(heading, comment_dict)
            vim.command('setlocal nomodified linebreak ' +
                'foldmethod=marker foldtext=CommentsFoldText() ' +
                'completefunc=BlogitComplete')
            if list(self.changed_comments(self.display())) != []:
                sys.stderr.write('Bug in BlogIt: Deactivating comment editing:\n')
                for d in self.changed_comments():
                    sys.stderr.write('  %s' % d['comment_id'])
                    #print list(self.changed_comments())
                vim.command('setlocal nomodifiable')
                self.current_comments = None


    def __init__(self):
        self._posts = {}
        self.prev_file = None
        self.NO_POST = BlogIt.NoPost()

    def _get_current_post(self):
        try:
            return self._posts[vim.current.buffer.number]
        except KeyError:
            return self.NO_POST

    def _set_current_post(self, post):
        """
        >>> vim.current.buffer.change_buffer(3)
        >>> blogit.current_post = { 'p3': 3 }
        >>> vim.current.buffer.change_buffer(7)
        >>> blogit.current_post    #doctest: +ELLIPSIS
        <__main__.NoPost object at 0x...>
        >>> blogit.current_post = { 'p7': 42 }
        >>> vim.current.buffer.change_buffer(3)
        >>> blogit.current_post
        {'p3': 3}
        """
        self._posts[vim.current.buffer.number] = post

    current_post = property(_get_current_post, _set_current_post)

    vimcommand_help = []

    def command(self, command='help', *args):
        """
        >>> mock('xmlrpclib')
        >>> mock('sys.stderr')
        >>> blogit.command('non-existant')
        Called sys.stderr.write('No such command: non-existant.')

        >>> def f(x): print 'got %s' % x
        >>> blogit.command_mocktest = f
        >>> blogit.command('mo')
        Called sys.stderr.write('Command mo takes 0 arguments.')

        >>> blogit.command('mo', 2)
        got 2

        >>> blogit.command_mockambiguous = f
        >>> blogit.command('mo')    #doctest: +NORMALIZE_WHITESPACE
        Called sys.stderr.write('Ambiguious command mo:
                mockambiguous, mocktest.')

        >>> minimock.restore()
        """
        def f(x): return x.startswith('command_' + command)
        matching_commands = filter(f, dir(self))

        if len(matching_commands) == 0:
            sys.stderr.write("No such command: %s." % command)
        elif len(matching_commands) == 1:
            try:
                getattr(self, matching_commands[0])(*args)
            except BlogIt.NoPostException:
                sys.stderr.write('No Post in current buffer.')
            except TypeError, e:
                try:
                    sys.stderr.write("Command %s takes %s arguments." % \
                            (command, int(str(e).split(' ')[3]) - 1))
                except:
                    sys.stderr.write('%s' % e)
        else:
            sys.stderr.write("Ambiguious command %s: %s." % ( command,
                    ', '.join([ s.replace('command_', '', 1)
                        for s in matching_commands ]) ))

    def list_comments(self):
        if vim.current.line.startswith('Status: '):
            p = BlogIt.WordPressCommentList(self.current_post.BLOG_POST_ID)
            vim.command('enew')
            p.getComments()
            self.current_post = p
            self.display(p)

    def list_edit(self):
        """
        >>> mock('vim.command')
        >>> vim.current.window.cursor = (1, 2)
        >>> vim.current.buffer[:] = [ '12 random text' ]
        >>> blogit.list_edit()
        Called vim.command('bdelete')
        Called vim.command('Blogit edit 12')

        >>> vim.current.buffer[:] = [ 'no blog id 12' ]
        >>> mock('blogit.command_new')
        >>> blogit.list_edit()
        Called vim.command('bdelete')
        Called blogit.command_new()

        >>> minimock.restore()
        """
        row, col = vim.current.window.cursor
        id = vim.current.buffer[row-1].split()[0]
        try:
            id = int(id)
        except ValueError:
            vim.command('bdelete')
            self.command_new()
        else:
            vim.command('bdelete')
            # To access vim s:variables we can't call this directly
            # via command_edit
            vim.command('Blogit edit %s' % id)

    @staticmethod
    def str_to_DateTime(text='', format='%c'):
        """
        >>> BlogIt.str_to_DateTime()                    #doctest: +ELLIPSIS
        <DateTime ...>

        >>> BlogIt.str_to_DateTime('Sun Jun 28 19:38:58 2009',
        ...         '%a %b %d %H:%M:%S %Y')             #doctest: +ELLIPSIS
        <DateTime '20090628T17:38:58' at ...>

        >>> BlogIt.str_to_DateTime(BlogIt.DateTime_to_str(
        ...         DateTime('20090628T17:38:58')))     #doctest: +ELLIPSIS
        <DateTime '20090628T17:38:58' at ...>
        """
        if text == '':
            text = localtime()
        else:
            text = strptime(text, format)
        return DateTime(strftime('%Y%m%dT%H:%M:%S', gmtime(mktime(text))))

    @staticmethod
    def DateTime_to_str(date, format='%c'):
        """
        >>> BlogIt.DateTime_to_str(DateTime('20090628T17:38:58'),
        ...         '%a %b %d %H:%M:%S %Y')
        u'Sun Jun 28 19:38:58 2009'

        >>> BlogIt.DateTime_to_str('invalid input')
        ''
        """
        try:
            return unicode(strftime(format,
                    localtime(timegm(strptime(str(date), '%Y%m%dT%H:%M:%S')))),
                    getpreferredencoding(), 'ignore')
        except ValueError:
            return ''

    def vimcommand(f, register_to=vimcommand_help):
        r"""
        >>> class C:
        ...     def command_f(self):
        ...         ' A method. '
        ...         print "f should not be executed."
        ...     def command_g(self, one, two):
        ...         ' A method with options. '
        ...         print "g should not be executed."
        ...
        >>> L = []
        >>> BlogIt.vimcommand(C.command_f, L)
        <unbound method C.command_f>
        >>> L
        [':Blogit f                  A method. \n']

        >>> BlogIt.vimcommand(C.command_g, L)
        <unbound method C.command_g>
        >>> L     #doctest: +NORMALIZE_WHITESPACE
        [':Blogit f                  A method. \n',
         ':Blogit g <one> <two>      A method with options. \n']

        """

        def getArguments(func, skip=0):
            """
            Get arguments of a function as a string.
            skip is the number of skipped arguments.
            """
            skip += 1
            args, varargs, varkw, defaults = getargspec(func)
            arguments = list(args)
            if defaults:
                index = len(arguments)-1
                for default in reversed(defaults):
                    arguments[index] += "=%s" % default
                    index -= 1
            if varargs:
                arguments.append("*" + varargs)
            if varkw:
                arguments.append("**" + varkw)
            return "".join((" <%s>" % s for s in arguments[skip:]))

        command = ( f.func_name.replace('command_', ':Blogit ') +
                getArguments(f) )
        register_to.append('%-25s %s\n' % ( command, f.__doc__ ))
        return f

    def post_table(self, posts):
        """ Yields the rows of a table displaying the posts (at least one).

        >>> list(blogit.post_table([ {'postid': '1',
        ...     'date_created_gmt': DateTime('20090628T17:38:58'),
        ...     'title': 'A title'} ]))    #doctest: +NORMALIZE_WHITESPACE
        ['ID    Date        Title',
        u' 1    06/28/09    A title']
        >>> list(blogit.post_table([{'postid': id,
        ...     'date_created_gmt': DateTime(d), 'title': t}
        ...     for id, d, t in zip(( '7', '42' ),
        ...         ( '20090628T17:38:58', '20100628T17:38:58' ),
        ...         ( 'First Title', 'Second Title' )
        ...     )]))     #doctest: +NORMALIZE_WHITESPACE
        ['ID    Date        Title',
        u' 7    06/28/09    First Title',
        u'42    06/28/10    Second Title']

        """
        assert posts is not None
        yield "%sID    Date%sTitle" % \
                ( ' ' * ( len(posts[0]['postid']) - 2 ),
                ( ' ' * len(self.DateTime_to_str(
                posts[0]['date_created_gmt'], '%x')) ) )
        format = '%%%dd    %%s    %%s' % max(2, len(posts[0]['postid']))
        for p in posts:
            yield format % ( int(p['postid']),
                    self.DateTime_to_str(p['date_created_gmt'], '%x'),
                    p['title'] )

    @staticmethod
    def display(post):
        vim.current.buffer[:] = [ unicode(line, 'utf-8').encode('utf-8')
                                     for line in post.display() ]
        vim.command('setlocal nomodified')

    @vimcommand
    def command_ls(self):
        """ list all posts """
        try:
            p = self.current_post
            allposts = p.client.metaWeblog.getRecentPosts('',
                    p.vim_vars.blog_username, p.vim_vars.blog_password)
            if not allposts:
                sys.stderr.write("There are no posts.")
                return
            vim.command('botright new')
            self.current_post = None
            vim.current.buffer[:] = [ line.encode('utf-8')
                                      for line in self.post_table(allposts) ]
            vim.command('setlocal buftype=nofile bufhidden=wipe nobuflisted ' +
                    'noswapfile syntax=blogsyntax nomodifiable nowrap')
            vim.current.window.cursor = (2, 0)
            vim.command('nnoremap <buffer> <enter> :py blogit.list_edit()<cr>')
            vim.command('nnoremap <buffer> gf :py blogit.list_edit()<cr>')
        except Exception, err:
            sys.stderr.write("An error has occured: %s" % err)

    @vimcommand
    def command_new(self):
        """ create a new post """
        vim.command('enew')
        self.current_post = BlogIt.WordPressBlogPost.create_new_post()

    @vimcommand
    def command_this(self):
        """ make this a blog post """
        if self.current_post is self.NO_POST:
            self.current_post = BlogIt.WordPressBlogPost.create_new_post(
                    vim.current.buffer[:])
        else:
            sys.stderr.write("Already editing a post.")

    @vimcommand
    def command_edit(self, id):
        """ edit a post """
        try:
            id = int(id)
        except ValueError:
            sys.stderr.write("'id' must be an integer value.")
            return

        post = BlogIt.WordPressBlogPost(id)
        try:
            post.getPost()
        except Fault, e:
            sys.stderr.write('Blogit Fault: ' + e.faultString)
        else:
            vim.command('enew')
            post.init_vim_buffer()
            self.current_post = post

    @vimcommand
    def command_commit(self):
        """ commit current post or comments """
        p = self.current_post
        p.send(vim.current.buffer[:])
        self.display(p)

    @vimcommand
    def command_push(self):
        """ publish post """
        p = self.current_post
        p.send(vim.current.buffer[:], push=1)
        self.display(p)

    @vimcommand
    def command_unpush(self):
        """ unpublish post """
        p = self.current_post
        p.send(vim.current.buffer[:], push=1)
        self.display(p)

    @vimcommand
    def command_rm(self, id):
        """ remove a post """
        p = self.current_post
        try:
            id = int(id)
        except ValueError:
            sys.stderr.write("'id' must be an integer value.")
            return

        if p.BLOG_POST_ID == id:
            self.current_post = self.NO_POST
            vim.command('bdelete')
        try:
            p.client.metaWeblog.deletePost('', id, p.vim_vars.blog_username,
                                              p.vim_vars.blog_password)
        except Fault, e:
            sys.stderr.write(e.faultString)
            return
        sys.stdout.write('Article removed')

    @vimcommand
    def command_tags(self):
        """ update and list tags and categories"""
        p = self.current_post
        username, password = p.vim_vars.blog_username, p.vim_vars.blog_password
        multicall = xmlrpclib.MultiCall(p.client)
        multicall.wp.getCategories('', username, password)
        multicall.wp.getTags('', username, password)
        categories, tags = tuple(multicall())
        tags = [ tag['name'] for tag in tags ]
        categories = [ cat['categoryName'] for cat in categories ]
        vim.command('let s:used_tags = %s' % tags)
        vim.command('let s:used_categories = %s' % categories)
        sys.stdout.write('\n \n \nCategories\n==========\n \n' + ', '.join(categories))
        sys.stdout.write('\n \n \nTags\n====\n \n' + ', '.join(tags))

    @vimcommand
    def command_preview(self):
        """ preview current post locally """
        p = self.current_post
        if instanceof(p, CommentList):
            raise Blogit.NoPostException
        if self.prev_file is None:
            self.prev_file = tempfile.mkstemp('.html', 'blogit')[1]
        f = open(self.prev_file, 'w')
        f.write(p.read_post(vim.current.buffer[:])[p.POST_BODY])
        f.flush()
        f.close()
        webbrowser.open(self.prev_file)

    @vimcommand
    def command_help(self):
        """ display this notice """
        sys.stdout.write("Available commands:\n")
        for f in self.vimcommand_help:
            sys.stdout.write('   ' + f)

    # needed for testing. Prevents beeing used as a decorator if it isn't at
    # the end.
    vimcommand = staticmethod(vimcommand)


blogit = BlogIt()

if doctest:
    doctest.testmod()
