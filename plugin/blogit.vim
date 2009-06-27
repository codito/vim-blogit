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
" Version:      1.1
" Last Change:  2009 June 21
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

function CompleteCategories(findstart, base)
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
        if getline('.') =~? '^Categories: '
            let L = s:used_categories
        elseif getline('.') =~? '^Tags: '
            let L = s:used_tags
        else
            return []
        endif
	    let res = []
	    for m in L
	        if m =~ '^' . a:base
		        call add(res, m . ', ')
	        endif
	    endfor
	    return res
    endif
endfunction

python <<EOF
# -*- coding: utf-8 -*-
import vim, xmlrpclib, sys, re
from time import mktime, strptime, strftime, localtime, gmtime
from calendar import timegm
from subprocess import Popen, CalledProcessError, PIPE
from xmlrpclib import DateTime, Fault, MultiCall
from inspect import getargspec
from types import MethodType

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
        self.post = {}

    def connect(self):
        self.client = xmlrpclib.ServerProxy(self.blog_url)

    def get_current_post(self):
        try:
            return self.post[vim.current.buffer.number]
        except KeyError:
            return None

    def set_current_post(self, value):
        self.post[vim.current.buffer.number] = value

    current_post = property(get_current_post, set_current_post)

    def command(self, command='help', *args):
        if self.client is None:
            self.connect()
        try:
            getattr(self, 'command_' + command)(*args)
        except AttributeError:
            sys.stderr.write("No such command: %s" % command)
        except TypeError, e:
            try:
                sys.stderr.write("Command %s takes %s arguments" % \
                        (command, int(str(e).split(' ')[3]) - 1))
            except:
                sys.stderr.write('%s' % e)

    def list_comments(self):
        if vim.current.line.startswith('Status: '):
            self.getComments(self.current_post['postid'])

    def list_edit(self):
        row, col = vim.current.window.cursor
        id = vim.current.buffer[row-1].split()[0]
        vim.command('bdelete')
        self.command_edit(int(id))

    meta_data_dict = { 'From': 'wp_author_display_name', 'Post-Id': 'postid',
            'Subject': 'title', 'Categories': 'categories',
            'Tags': 'mt_keywords', 'Date': 'date_created_gmt', 
            'Status': 'blogit_status',
           }

    def display_post(self, post={}, new_text=None):
        def display_comment_count(d):
            if d['awaiting_moderation'] > 0:
                if d['spam'] > 0:
                    s = u' (%(awaiting_moderation)s awaiting, %(spam)s spam)'
                else:
                    s = u'%(awaiting_moderation)s'
            elif d['spam'] > 0:
                s = u' (%(spam)s spam)'
            else:
                s = u''
            return ( u'%(post_status)s – %(total_comments)s Comments' + s ) % d

        default_post = { 'post_status': 'draft',
                         self.meta_data_dict['From']: self.blog_username }
        default_post.update(post)
        post = default_post
        meta_data_f_dict = { 'Date': self.DateTime_to_str,
                   'Categories': lambda L: ', '.join(L),
                   'Status': display_comment_count
                 }
        vim.current.buffer[:] = None
        vim.command("setlocal ft=mail completefunc=CompleteCategories")
        for label in [ 'From', 'Post-Id', 'Subject', 'Status', 'Categories',
                'Tags', 'Date' ]:
            try:
                val = post[self.meta_data_dict[label]]
            except KeyError:
                val = ''
            if label in meta_data_f_dict:
                val = meta_data_f_dict[label](val)
            vim.current.buffer.append('%s: %s' % ( label,
                    unicode(val).encode('utf-8') ))
        vim.current.buffer[0] = None
        vim.current.buffer.append('')
        if new_text is None:
            content = self.unformat(post.get('description', '')\
                        .encode("utf-8")).split('\n')
        else:
            content = new_text
        for line in content:
            vim.current.buffer.append(line)

        if post.get('mt_text_more'):
            vim.current.buffer.append('')
            vim.current.buffer.append('<!--more-->')
            vim.current.buffer.append('')
            content = self.unformat(post["mt_text_more"].encode("utf-8"))
            for line in content.split('\n'):
                vim.current.buffer.append(line)

        vim.current.window.cursor = (8, 0)
        vim.command('set nomodified')
        vim.command('set textwidth=0')
        self.current_post = post
        vim.command('nnoremap <buffer> gf :py blogit.list_comments()<cr>')

    def str_to_DateTime(self, text=''):
        if text == '':
            text = localtime()
        else:
            text = strptime(text, '%c')
        return DateTime(strftime('%Y%m%dT%H:%M:%S', gmtime(mktime(text))))

    def DateTime_to_str(self, date, format='%c'):
        try:
            return strftime(format, localtime(timegm(strptime(str(date),
                                              '%Y%m%dT%H:%M:%S'))))
        except ValueError:
            return ''

    def getPost(self, id):
        username, password = self.blog_username, self.blog_password
        multicall = xmlrpclib.MultiCall(self.client)
        multicall.metaWeblog.getPost(id, username, password)
        multicall.wp.getCommentCount('', username, password, id)
        if vim.eval('s:used_tags == [] || s:used_categories == []') != '0':
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

    def getComments(self, id, offset=0):
        # TODO
        vim.command('enew')
        for comment in self.client.wp.getComments('', blogit.blog_username, 
                blogit.blog_password, [ id, '', offset, 1000 ]):
            for header in ( 'status', 'author', 'comment_id', 'parent', 
                        'date_created_gmt', 'type'  ):
                vim.current.buffer.append('%s: %s' % 
                        ( header, comment[header] ))
            vim.current.buffer.append('')
            for line in comment['content'].split('\n'):
                vim.current.buffer.append(line.encode('utf-8'))
            vim.current.buffer.append('=' * 78)
            vim.current.buffer.append('')
        vim.command('set nomodifiable')

    def getMeta(self):
        r = re.compile('^(.*?): (.*)$')
        for line in vim.current.buffer:
            if line.rstrip == '':
                return
            m = r.match(line)
            if m:
                yield m.group(1, 2)

    def getText(self, start_text):
        """

        Can raise FilterException.
        """
        text = '\n'.join(vim.current.buffer[start_text:])
        return map(self.format, text.split('\n<!--more-->\n\n'))

    def unformat(self, text):
        try:
            return self.format(text, 'blogit_unformat')
        except self.FilterException, e:
            sys.stderr.write(e.message)
            return e.input_text

    def format(self, text, vim_var='blogit_format'):
        """ Filter text with command in vim_var.

        Can raise FilterException.
        """
        if not vim.eval('exists("%s")' % vim_var) != '0':
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

    def getCategories(self):
        """ Returns a list of used categories from the server (slow).

        Side effect: Sets vim variable s:used_categories for omni-completion.
        """
        categories = [ cat['categoryName']
                for cat in self.client.wp.getCategories('',
                    self.blog_username, self.blog_password) ]
        vim.command('let s:used_categories = %s' % categories)
        return categories

    @property
    def blog_username(self):
        return vim.eval(self.blog_name + '_username')

    @property
    def blog_password(self):
        return vim.eval(self.blog_name + '_password')

    @property
    def blog_url(self):
        return vim.eval(self.blog_name + '_url')

    @property
    def blog_name(self):
        if vim.eval("exists('b:blog_name')") != '0':
            return vim.eval('b:blog_name')
        elif vim.eval("exists('blog_name')") != '0':
            return vim.eval('blog_name')
        else:
            return 'blogit'

    vimcommand_list = []

    def vimcommand(f, register_to=vimcommand_list):
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
        f.vimcommand = '%-25s %s\n' % ( command, f.__doc__ )
        register_to.append(f)
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
        """ commit current post """
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
        for f in self.vimcommand_list:
            sys.stdout.write('   ' + f.vimcommand)


blogit = BlogIt()
