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
" Version:      1.2
" Last Change:  2009 July 18
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
" ":Blogit help"
"   Display help
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

function BlogitComplete(findstart, base)
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

function CommentsFoldText()
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
try:
    import vim
except ImportError:
    # Used outside of vim (for testing)
    from minimock import Mock, mock
    import doctest, minimock
    vim = Mock('vim')
else:
    doctest = False
import xmlrpclib, sys, re
from time import mktime, strptime, strftime, localtime, gmtime
from calendar import timegm
from subprocess import Popen, CalledProcessError, PIPE
from xmlrpclib import DateTime, Fault, MultiCall
from inspect import getargspec

#####################
# Do not edit below #
#####################

class BlogIt:
    class FilterException(Exception):
        def __init__(self, message, input_text, filter):
            self.message = "Blogit: Error happend while filtering with:" + \
                    filter + '\n' + message
            self.input_text = input_text
            self.filter = filter

    def __init__(self):
        self.client = None
        self._posts = {}
        self._comments = {}

    def connect(self):
        self.client = xmlrpclib.ServerProxy(self.blog_url)

    def buffer_property(var_name):

        def get_current_post(self):
            try:
                return getattr(self, var_name)[vim.current.buffer.number]
            except KeyError:
                return None

        def set_current_post(self, value):
            getattr(self, var_name)[vim.current.buffer.number] = value

        return property(get_current_post, set_current_post)

    current_post = buffer_property('_posts')
    current_comments = buffer_property('_comments')

    meta_data_dict = { 'From': 'wp_author_display_name', 'Post-Id': 'postid',
            'Subject': 'title', 'Categories': 'categories',
            'Tags': 'mt_keywords', 'Date': 'date_created_gmt',
            'Status': 'blogit_status',
           }

    comments_meta_data_dict = { 'Status': 'status', 'Author': 'author',
            'ID': 'comment_id', 'Parent': 'parent',
            'Date': 'date_created_gmt', 'Type': 'type', 'content': 'content',
           }

    vimcommand_help = []

    def command(self, command='help', *args):
        """
        >>> xmlrpclib = Mock('xmlrpclib')
        >>> sys.stderr = Mock('stderr')
        >>> blogit.command('non-existant')
        Called vim.eval('blogit_url')
        Called stderr.write('No such command: non-existant.')

        >>> def f(x): print 'got %s' % x
        >>> blogit.command_mocktest = f
        >>> blogit.command('mo')
        Called stderr.write('Command mo takes 0 arguments.')

        >>> blogit.command('mo', 2)
        got 2

        >>> blogit.command_mockambiguous = f
        >>> blogit.command('mo')
        Called stderr.write('Ambiguious command mo: mockambiguous, mocktest.')
        """
        if self.client is None:
            self.connect()
        def f(x): return x.startswith('command_' + command)
        matching_commands = filter(f, dir(self))

        if len(matching_commands) == 0:
            sys.stderr.write("No such command: %s." % command)
        elif len(matching_commands) == 1:
            try:
                getattr(self, matching_commands[0])(*args)
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
            self.getComments(self.current_post['postid'])

    def list_edit(self):
        """
        >>> vim.command = Mock('vim.command')
        >>> vim.current.window.cursor = (1, 2)
        >>> vim.current.buffer = [ '12 random text' ]
        >>> blogit.list_edit()
        Called vim.command('bdelete')
        Called vim.command('Blogit edit 12')

        >>> vim.current.buffer = [ 'no blog id 12' ]
        >>> blogit.command_new = Mock('self.command_new')
        >>> blogit.list_edit()
        Called vim.command('bdelete')
        Called self.command_new()
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

    def append_post(self, post_data, post_body, headers,
            meta_data_dict, meta_data_f_dict={}, unformat=False):
        """
        Append a post or comment to the vim buffer.
        """
        is_first_post_in_buffer = False
        if vim.current.buffer[:] == ['']:
            # work around empty buffer has one line.
            is_first_post_in_buffer = True
        for label in headers:
            try:
                val = post_data[meta_data_dict[label]]
            except KeyError:
                val = ''
            if label in meta_data_f_dict:
                val = meta_data_f_dict[label](val)
            vim.current.buffer.append('%s: %s' % ( label,
                    unicode(val).encode('utf-8') ))
        if is_first_post_in_buffer:
            # work around empty buffer has one line.
            vim.current.buffer[0] = None
        vim.current.buffer.append('')
        content = post_data.get(post_body, '').encode("utf-8")
        if unformat:
            content = self.unformat(content)
        for line in content.split('\n'):
            vim.current.buffer.append(line)

        if post_data.get('mt_text_more'):
            vim.current.buffer.append('')
            vim.current.buffer.append('<!--more-->')
            vim.current.buffer.append('')
            content = self.unformat(post_data["mt_text_more"].encode("utf-8"))
            for line in content.split('\n'):
                vim.current.buffer.append(line)

    def display_post(self, post={}, new_text=None):
        def display_comment_count(d):
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
            return ( u'%(post_status)s \u2013 %(total_comments)s Comments' + s ) % d

        do_unformat = True
        default_post = { 'post_status': 'draft',
                         self.meta_data_dict['From']: self.blog_username }
        default_post.update(post)
        post = default_post
        meta_data_f_dict = { 'Date': self.DateTime_to_str,
                   'Categories': lambda L: ', '.join(L),
                   'Status': display_comment_count
                 }
        vim.current.buffer[:] = None
        if new_text is not None:
            post['description'] = new_text
            do_unformat = False
        self.append_post(post, 'description',
                [ 'From', 'Post-Id', 'Subject', 'Status', 'Categories',
                    'Tags', 'Date'
                ], self.meta_data_dict, meta_data_f_dict, do_unformat)
        self.current_post = post
        vim.command('nnoremap <buffer> gf :py blogit.list_comments()<cr>')
        vim.command('setlocal nomodified ft=mail textwidth=0 ' +
                             'completefunc=BlogitComplete')
        vim.current.window.cursor = (8, 0)

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
        'Sun Jun 28 19:38:58 2009'

        >>> BlogIt.DateTime_to_str('invalid input')
        ''
        """
        try:
            return strftime(format, localtime(timegm(strptime(str(date),
                                              '%Y%m%dT%H:%M:%S'))))
        except ValueError:
            return ''

    def getPost(self, id):
        """
        >>> blogit.blog_username, blogit.blog_password = 'user', 'password'
        >>> blogit.client = Mock('client')
        >>> xmlrpclib.MultiCall = Mock('xmlrpclib.MultiCall', returns=Mock(
        ...         'multicall', returns=[{'post_status': 'draft'}, {}]))
        >>> d = blogit.getPost(42)    #doctest: +ELLIPSIS
        Called xmlrpclib.MultiCall(<Mock 0x... client>)
        Called multicall.metaWeblog.getPost(42, 'user', 'password')
        Called multicall.wp.getCommentCount('', 'user', 'password', 42)
        Called vim.eval('s:used_tags == [] || s:used_categories == []')
        Called multicall()
        >>> sorted(d.items())
        [('blogit_status', {'post_status': 'draft'}), ('post_status', 'draft')]
        """
        username, password = self.blog_username, self.blog_password
        multicall = xmlrpclib.MultiCall(self.client)
        multicall.metaWeblog.getPost(id, username, password)
        multicall.wp.getCommentCount('', username, password, id)
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
        return d

    def getComments(self, id=None, offset=0):
        """ Lists the comments to a post with given id in a new buffer.

        >>> blogit.client = Mock('client')
        >>> xmlrpclib.MultiCall = Mock('xmlrpclib.MultiCall', returns=Mock(
        ...         'multicall', returns=[], tracker=None))
        >>> vim.command = Mock('vim.command')
        >>> blogit.blog_username = 'User Name'
        >>> blogit.append_comment_to_buffer = Mock('append_comment_to_buffer')
        >>> blogit.changed_comments = Mock('changed_comments', returns=[])
        >>> blogit.getComments(42)   #doctest: +ELLIPSIS +NORMALIZE_WHITESPACE
        Called vim.command('enew')
        Called xmlrpclib.MultiCall(<Mock 0x... client>)
        Called vim.eval('blogit_password')
        Called vim.eval('blogit_password')
        Called vim.eval('blogit_password')
        Called append_comment_to_buffer()
        Called vim.command(
            'setlocal nomodified linebreak
                      foldmethod=marker foldtext=CommentsFoldText()
                      completefunc=BlogitComplete')
        Called changed_comments()
        """
        if id is None:
            id = self.current_comments['blog_id']
            vim.current.buffer[:] = None
        else:
            vim.command('enew')
        self.current_comments = { 'blog_id': id }
        multicall = xmlrpclib.MultiCall(self.client)
        for comment_typ in ( 'hold', 'spam', 'approve' ):
            multicall.wp.getComments('',
                    self.blog_username, blogit.blog_password,
                    { 'post_id': id, 'status': comment_typ,
                      'offset': offset, 'number': 1000 })
        self.append_comment_to_buffer()
        for comments, heading in zip(multicall(),
                ( 'In Moderadation', 'Spam', 'Published' )):
            if comments == []:
                continue

            vim.current.buffer[-1] = 72 * '=' + ' {{{1'
            vim.current.buffer.append(5 * ' ' + heading)
            vim.current.buffer.append('')

            fold_levels = {}
            for comment in reversed(comments):
                try:
                    fold = fold_levels[comment['parent']] + 2
                except KeyError:
                    fold = 2
                fold_levels[comment['post_id']] = fold
                self.append_comment_to_buffer(comment, fold)
        vim.command('setlocal nomodified linebreak ' +
            'foldmethod=marker foldtext=CommentsFoldText() ' +
            'completefunc=BlogitComplete')
        if type(self.current_comments['blog_id']) == dict:
            # no comment should have id 'blog_id'.
            sys.stderr.write('A comment used reserved id "blog_id"')
        elif list(self.changed_comments()) != []:
            sys.stderr.write('Bug in BlogIt: Deactivating comment editing:\n')
            for d in self.changed_comments():
                sys.stderr.write('  %s' % d['comment_id'])
            #print list(self.changed_comments())
        else:
            return
        vim.command('setlocal nomodifiable')
        del self.current_comments

    def changed_comments(self):
        """ Yields comments with changes made to in the vim buffer.

        >>> blogit.current_comments = { '': { 'status': 'new'},
        ...     '1': { 'content': 'Old Text', 'status': 'hold',
        ...             'unknown': 'tag'},
        ...     '2': { 'content': 'Same Text', 'Date': 'old', 'status': 'hold'},
        ...     '3': { 'content': 'Same Again', 'status': 'hold'} }
        >>> vim.current.buffer = [
        ...     60 * '=', 'ID: 1 ', 'Status: hold', '', 'Changed Text',
        ...     60 * '=', 'ID:  ', 'Status: hold', '', 'New Text',
        ...     60 * '=', 'ID: 2', 'Status: hold', 'Date: new', '', 'Same Text',
        ...     60 * '=', 'ID: 3', 'Status: spam', '', 'Same Again',
        ... ]
        >>> list(blogit.changed_comments())
        [{'content': u'Changed Text', 'status': u'hold', 'unknown': 'tag'}, {'status': u'hold', 'content': u'New Text'}, {'content': u'Same Again', 'status': u'spam'}]
        """
        ignored_tags = set([ 'ID', 'Date' ])

        for comment in self.read_comments():
            original_comment = self.current_comments[comment['ID']]
            updated_comment = original_comment.copy()
            for t in comment.keys():
                if t in ignored_tags:
                    continue
                updated_comment[self.comments_meta_data_dict[t]] = \
                        comment[t].decode('utf-8')
            if original_comment != updated_comment:
                yield updated_comment

    def read_comments(self):
        r""" Yields a dict for each comment in the current buffer.

        >>> vim.current.buffer = [
        ...     60 * '=', 'section header',
        ...     60 * '=', 'Tag2: Val2 ',
        ...     60 * '=',
        ...     'Tag:  Value  ', '', 'Some Text', 'in two lines.', '', '',
        ... ]
        >>> list(blogit.read_comments())
        [{'content': 'Some Text\nin two lines.', 'Tag': 'Value'}]
        """

        def process_comment(headers, body):
            for i, line in reversed(list(enumerate(body))):
                if line.strip() != '':
                    body = body[:i+1]
                    break
            else:    # body is whitespace
                return None
            d = { 'content': '\n'.join(body) }
            for t, v in self.getMeta(headers):
                d[t.strip()] = v.strip()
            return d

        headers = []
        body = []
        current_section = headers
        for line in vim.current.buffer:
            if line.startswith(60 * '='):
                c = process_comment(headers, body)
                headers, body = [], []
                current_section = headers
                if c is not None:
                    yield c
            if current_section == headers and line.strip() == '':
                current_section = body
                continue
            current_section.append(line)
        c = process_comment(headers, body)
        if c is not None:
            yield c

    def append_comment_to_buffer(self, comment=None, fold_level=1):
        """
        Formats and appends a given comment to the current buffer. Appends
        an comment template if None is given.

        >>> vim.current.buffer = ['']
        >>> blogit.current_comments = { 'blog_id': 0 }
        >>> blogit.blog_username = 'User Name'
        >>> blogit.append_comment_to_buffer()
        >>> vim.current.buffer   #doctest: +NORMALIZE_WHITESPACE
        ['======================================================================== {{{1',
        'Status: new',
        'Author: User Name',
        'ID: ',
        'Parent: 0',
        'Date: ',
        'Type: ',
        '',
        '',
        '',
        '']
        """
        meta_data_f_dict = { 'Date': self.DateTime_to_str }
        if comment is None:
            comment = { 'status': 'new', 'author': self.blog_username,
                        'comment_id': '', 'parent': '0',
                        'date_created_gmt': '', 'type': '', 'content': ''
                      }
        vim.current.buffer[-1] = 72 * '=' + ' {{{%s' % fold_level
        self.append_post(comment, 'content', [ 'Status', 'Author',
                'ID', 'Parent', 'Date', 'Type' ],
                self.comments_meta_data_dict, meta_data_f_dict)
        vim.current.buffer.append('')
        vim.current.buffer.append('')
        self.current_comments[str(comment['comment_id'])] = comment

    def getMeta(self, text=None):
        """
        Reads the meta-data in the current buffer. Outputed as dictionary.

        >>> list(blogit.getMeta([ 'tag: value', '', 'body: novalue' ]))
        [('tag', 'value')]
        """
        if text is None:
            text = vim.current.buffer
        r = re.compile('^(.*?): (.*)$')
        for line in text:
            if line.rstrip() == '':
                return
            m = r.match(line)
            if m:
                yield m.group(1, 2)

    def getText(self, start_line):
        r"""
        Read the blog text from vim buffer. start_line is the first
        line which is part of the test (not headers). Text is then formated
        as defined by vim variable blogit_format.

        Can raise FilterException.

        >>> vim.current.buffer = [ 'one', 'two', 'tree', 'four' ]

        >>> blogit.getText(0)
        Called vim.eval('exists("blogit_format")')
        ['one\ntwo\ntree\nfour']

        >>> blogit.getText(1)
        Called vim.eval('exists("blogit_format")')
        ['two\ntree\nfour']

        >>> blogit.getText(4)
        Called vim.eval('exists("blogit_format")')
        ['']

        >>> vim.eval = Mock('vim.eval', returns_iter=['1', 'sort'])
        >>> blogit.getText(0)
        Called vim.eval('exists("blogit_format")')
        Called vim.eval('blogit_format')
        ['four\none\ntree\ntwo\n']

        >>> vim.eval = Mock('vim.eval', returns_iter=['1', 'false'])
        >>> blogit.getText(0)     # can't get this to work :'(
        Traceback (most recent call last):
            ...
        FilterException
        """
        text = '\n'.join(vim.current.buffer[start_line:])
        return map(self.format, text.split('\n<!--more-->\n\n'))

    def unformat(self, text):
        r"""
        >>> old = vim.eval
        >>> vim.eval = Mock('vim.eval', returns_iter=[ '1', 'false' ])
        >>> blogit.unformat('some random text')
        ...         #doctest: +NORMALIZE_WHITESPACE
        Called vim.eval('exists("blogit_unformat")')
        Called vim.eval('blogit_unformat')
        Called stderr.write('Blogit: Error happend while filtering
                with:false\n')
        'some random text'

        >>> vim.eval = old
        """
        try:
            return self.format(text, 'blogit_unformat')
        except self.FilterException, e:
            sys.stderr.write(e.message)
            return e.input_text

    def format(self, text, vim_var='blogit_format'):
        r""" Filter text with command in vim_var.

        Can raise FilterException.

        >>> blogit.format('some random text')
        Called vim.eval('exists("blogit_format")')
        'some random text'

        >>> old = vim.eval
        >>> vim.eval = Mock('vim.eval', returns_iter=[ '1', 'false' ])
        >>> blogit.format('some random text')
        Traceback (most recent call last):
            ...
        FilterException

        >>> vim.eval = Mock('vim.eval', returns_iter=[ '1', 'rev' ])
        >>> blogit.format('')
        Called vim.eval('exists("blogit_format")')
        Called vim.eval('blogit_format')
        ''

        >>> vim.eval = Mock('vim.eval', returns_iter=[ '1', 'rev' ])
        >>> blogit.format('some random text')
        Called vim.eval('exists("blogit_format")')
        Called vim.eval('blogit_format')
        'txet modnar emos\n'

        >>> vim.eval = Mock('vim.eval', returns_iter=[ '1', 'rev' ])
        >>> blogit.format('some random text\nwith a second line')
        Called vim.eval('exists("blogit_format")')
        Called vim.eval('blogit_format')
        'txet modnar emos\nenil dnoces a htiw\n'

        >>> vim.eval = old

        """
        if not vim.eval('exists("%s")' % vim_var) == '1':
            return text
        try:
            filter = vim.eval(vim_var)
            p = Popen(filter, shell=True, stdin=PIPE, stdout=PIPE, stderr=PIPE)
            p.stdin.write(text)
            p.stdin.close()
            if p.wait():
                raise self.FilterException(p.stderr.read(), text, filter)
            return p.stdout.read()
        except self.FilterException:
            raise
        except Exception, e:
            raise self.FilterException(e.message, text, filter)

    def sendArticle(self, push=None):

        def sendPost(postid, post, push):
            """ Unify newPost and editPost from the metaWeblog API. """
            if postid == '':
                postid = self.client.metaWeblog.newPost('', self.blog_username,
                                                self.blog_password, post, push)
            else:
                self.client.metaWeblog.editPost(postid, self.blog_username,
                                                self.blog_password, post, push)
            return postid

        def date_from_meta(str_date):
            if push is None and self.current_post['post_status'] == 'publish':
                return self.str_to_DateTime(str_date)
            return self.str_to_DateTime()

        def split_comma(x): return x.split(', ')

        if self.current_post is None:
            sys.stderr.write("Not editing a post.")
            return
        try:
            vim.command('set nomodified')
            start_text = 0
            for line in vim.current.buffer:
                start_text += 1
                if line == '':
                    break

            post = self.current_post.copy()
            meta_data_f_dict = { 'Categories': split_comma,
                                 'Date': date_from_meta }

            for label, value in self.getMeta():
                if self.meta_data_dict[label].startswith('blogit_'):
                    continue
                if label in meta_data_f_dict:
                    value = meta_data_f_dict[label](value)
                post[self.meta_data_dict[label]] = value

            push_dict = { 0: 'draft', 1: 'publish',
                          None: self.current_post['post_status'] }
            post['post_status'] = push_dict[push]
            if push is None:
                push = 0

            textl = self.getText(start_text)
            post['description'] = textl[0]
            if len(textl) > 1:
                post['mt_text_more'] = textl[1]

            postid = sendPost(post['postid'], post, push)
            self.display_post(self.getPost(postid))
        except self.FilterException, e:
            sys.stderr.write(e.message)
        except Fault, e:
            sys.stderr.write(e.faultString)

    def sendComments(self):
        """ Send changed and new comments to server.

        >>> blogit.current_comment = { 'blog_id': 42 }
        >>> mock('blogit.getComments')
        >>> mock('blogit.changed_comments',
        ...         returns=[ { 'status': 'new', 'content': 'New Text' },
        ...             { 'status': 'will fail', 'comment_id': 13 },
        ...             { 'status': 'will succeed', 'comment_id': 7 },
        ...             { 'status': 'rm', 'comment_id': 100 } ])
        >>> mock('xmlrpclib.MultiCall', returns=Mock(
        ...         'multicall', returns=[ 200, False, True, True ]))
        >>> blogit.sendComments()    #doctest: +ELLIPSIS, +NORMALIZE_WHITESPACE
        Called xmlrpclib.MultiCall(<Mock 0x... client>)
        Called blogit.changed_comments()
        Called multicall.wp.newComment(
            '', 'user', 'password', 42,
            {'status': 'approve', 'content': 'New Text'})
        Called multicall.wp.editComment(
            '', 'user', 'password', 13, {'status': 'will fail'})
        Called multicall.wp.editComment(
            '', 'user', 'password', 7, {'status': 'will succeed'})
        Called multicall.wp.deleteComment('', 'user', 'password', 100)
        Called multicall()
        Called stderr.write('Server refuses update to 13.')
        Called blogit.getComments()

        >>> minimock.restore()

        """
        multicall = xmlrpclib.MultiCall(self.client)
        username, password = self.blog_username, self.blog_password
        blog_id = self.current_comments['blog_id']
        multicall_log = []
        for comment in self.changed_comments():
            if comment['status'] == 'new':
                comment['status'] = 'approve'
                multicall.wp.newComment(
                        '', username, password, blog_id, comment)
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
        self.getComments()

    @property
    def blog_username(self):
        return vim.eval(self.blog_name + '_username')

    @property
    def blog_password(self):
        return vim.eval(self.blog_name + '_password')

    @property
    def blog_url(self):
        """
        >>> vim.eval.mock_returns = 'http://example.com'
        >>> blogit.blog_name='blogit'
        >>> blogit.blog_url
        Called vim.eval('blogit_url')
        'http://example.com'
        """
        return vim.eval(self.blog_name + '_url')

    @property
    def blog_name(self):
        """
        >>> vim.eval = Mock('vim.eval')
        >>> blogit.blog_name
        Called vim.eval("exists('b:blog_name')")
        Called vim.eval("exists('blog_name')")
        'blogit'

        """
        if vim.eval("exists('b:blog_name')") == '1':
            return vim.eval('b:blog_name')
        elif vim.eval("exists('blog_name')") == '1':
            return vim.eval('blog_name')
        else:
            return 'blogit'

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

    @vimcommand
    def command_ls(self):
        """ list all posts """
        try:
            allposts = self.client.metaWeblog.getRecentPosts('',
                    self.blog_username, self.blog_password)
            if not allposts:
                sys.stderr.write("There are no posts.")
                return
            vim.command('botright new')
            self.current_post = None
            vim.current.buffer[0] = "%sID    Date%sTitle" % \
                    ( ' ' * ( len(allposts[0]['postid']) - 2 ),
                    ( ' ' * len(self.DateTime_to_str(
                    allposts[0]['date_created_gmt'], '%x')) ) )
            format = '%%%dd    %%s    %%s' % max(2, len(allposts[0]['postid']))
            for p in allposts:
                vim.current.buffer.append(format % (int(p['postid']),
                        self.DateTime_to_str(p['date_created_gmt'], '%x'),
                        p['title'].encode('utf-8')))
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
        self.display_post()

    @vimcommand
    def command_this(self):
        """ make this a blog post """
        if self.current_post is None:
            self.display_post(new_text=vim.current.buffer[:])
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

        try:
            post = self.getPost(id)
        except Fault, e:
            sys.stderr.write('Blogit Fault: ' + e.faultString)
        else:
            vim.command('enew')
            self.display_post(post)

    @vimcommand
    def command_commit(self):
        """ commit current post or comments """
        if self.current_comments is not None:
            self.sendComments()
        else:
            self.sendArticle()

    @vimcommand
    def command_push(self):
        """ publish post """
        self.sendArticle(push=1)

    @vimcommand
    def command_unpush(self):
        """ unpublish post """
        self.sendArticle(push=0)

    @vimcommand
    def command_rm(self, id):
        """ remove a post """
        try:
            id = int(id)
        except ValueError:
            sys.stderr.write("'id' must be an integer value.")
            return

        if self.current_post and int(self.current_post['postid']) == int(id):
            vim.command('bdelete')
            self.current_post = None
        try:
            self.client.metaWeblog.deletePost('', id, self.blog_username,
                                              self.blog_password)
        except Fault, e:
            sys.stderr.write(e.faultString)
            return
        sys.stdout.write('Article removed')

    @vimcommand
    def command_tags(self):
        """ update and list tags and categories"""
        username, password = self.blog_username, self.blog_password
        multicall = xmlrpclib.MultiCall(self.client)
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
