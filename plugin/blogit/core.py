#!/usr/bin/env python

import xmlrpclib
import sys
from inspect import getargspec
import webbrowser
import tempfile
import warnings
import gettext
from functools import partial
from blogit import utils, blogclient

gettext.textdomain('blogit')
_ = gettext.gettext

try:
    import vim
except ImportError:
    # Used outside of vim (for testing)
    import doctest, minimock
    from minimock import Mock, mock
    from tests.mock_vim import vim
else:
    doctest = None

#warnings.simplefilter('ignore', Warning)
warnings.simplefilter('always', UnicodeWarning)

class NoPost(object):
    BLOG_POST_ID = ''

    @property
    def client(self):
        return blogclient.AbstractBlogClient(self.vim_vars)

    @property
    def vim_vars(self):
        return utils.VimVars()

    def __getattr__(self, name):
        raise utils.NoPostException

class BlogIt(object):
    vimcommand_help = []

    def __init__(self):
        self._posts = {}
        self.prev_file = None
        self.NO_POST = NoPost()

    def _get_current_post(self):
        try:
            return self._posts[vim.current.buffer.number]
        except KeyError:
            return self.NO_POST

    def _set_current_post(self, post):
        """
        >>> vim.current.buffer.change_buffer(3)
        >>> blogit.current_post = Mock('post@buffer_3_', tracker=None)
        >>> vim.current.buffer.change_buffer(7)
        >>> blogit.current_post    #doctest: +ELLIPSIS
        <blogit.core.NoPost object at 0x...>
        >>> blogit.current_post = Mock('post@buffer_7_', tracker=None)
        >>> vim.current.buffer.change_buffer(3)
        >>> blogit.current_post    #doctest: +ELLIPSIS
        <Mock 0x... post@buffer_3_>
        >>> vim.current.buffer.change_buffer(42)
        """
        self._posts[vim.current.buffer.number] = post
        post.vim_vars.export_blog_name()
        post.vim_vars.export_post_type(post)

    current_post = property(_get_current_post, _set_current_post)

    def get_command(self, bang='', command='help', *args):
        """ Interface called by vim user-function ':Blogit'. Returns the appropriate command_*
        function which will handle user request.

        >>> mock('xmlrpclib')
        >>> mock('sys.stderr')
        >>> blogit.get_command('', 'non-existant')
        Called sys.stderr.write('No such command: non-existant.')

        >>> def f(x): print 'got %s' % x
        >>> blogit.command_mocktest = f
        >>> blogit.get_command('', 'mo')
        Called sys.stderr.write('Command mo takes 0 arguments.')

        >>> blogit.get_command('', 'mo', 2)
        got 2

        >>> blogit.command_mockambiguous = f
        >>> blogit.get_command('', 'mo')    #doctest: +NORMALIZE_WHITESPACE
        Called sys.stderr.write('Ambiguious command mo:
                mockambiguous, mocktest.')

        >>> mock('blogit.list_edit')
        >>> blogit.get_command('!', 'list_edit')
        Called blogit.list_edit()

        >>> minimock.restore()
        """
        if bang == '!':
            # Workaround limit to access vim s:variables when
            # called via :python.
            getattr(self, command)()
            return

        def f(x):
            return x.startswith('command_' + command)

        matching_commands = filter(f, dir(self))

        if len(matching_commands) == 0:
            sys.stderr.write("No such command: %s." % command)
        elif len(matching_commands) == 1:
            try:
                getattr(self, matching_commands[0])(*args)
            except utils.NoPostException:
                sys.stderr.write('No Post in current buffer.')
            except TypeError, e:
                try:
                    sys.stderr.write("Command %s takes %s arguments." % \
                            (command, int(str(e).split(' ')[3]) - 1))
                except:
                    sys.stderr.write('%s' % e)
            except Exception, e:
                sys.stderr.write(unicode(e))
        else:
            sys.stderr.write("Ambiguious command %s: %s." % (command,
                                                             ', '.join([s.replace('command_', '', 1)
                                                                       for s in matching_commands])))

    def register_vimcommand(f, doc_string, register_to=vimcommand_help):
        r"""
        >>> class C:
        ...     def command_f(self):
        ...         ' A method. '
        ...         print "f should not be executed."
        ...     def command_g(self, one, two):
        ...         ' A method with arguments. '
        ...         print "g should not be executed."
        ...     def command_h(self, one, two=None):
        ...         ' A method with an optional arguments. '
        >>> L = []
        >>> vim_cmd = lambda f, L: BlogIt.register_vimcommand(f, f.__doc__, L)
        >>> vim_cmd(C.command_f, L)
        <unbound method C.command_f>
        >>> L
        [':Blogit f                  A method. \n']

        >>> vim_cmd(C.command_g, L)
        <unbound method C.command_g>
        >>> L     #doctest: +NORMALIZE_WHITESPACE
        [':Blogit f                  A method. \n',
         ':Blogit g {one} {two}      A method with arguments. \n']
        >>> vim_cmd(C.command_h, L)
        <unbound method C.command_h>
        >>> L     #doctest: +NORMALIZE_WHITESPACE
        [':Blogit f                  A method. \n',
         ':Blogit g {one} {two}      A method with arguments. \n',
         ':Blogit h {one} [two]      A method with an optional arguments. \n']

        """

        def getArguments(func, skip=0):
            """
            Get arguments of a function as a string.
            skip is the number of skipped arguments.
            """
            skip += 1
            args, varargs, varkw, defaults = getargspec(func)
            cut = len(args)
            if defaults:
                cut -= len(defaults)
            args = ["{%s}" % a for a in args[skip:cut]] + \
                   ["[%s]" % a for a in args[cut:]]
            if varargs:
                args.append("[*%s]" % varargs)
            if varkw:
                args.append("[**%s]" % varkw)
            return " ".join(args)

        command = '%s %s' % (f.func_name.replace('command_', ':Blogit '),
                             getArguments(f))
        register_to.append('%-25s %s\n' % (command, doc_string))
        return f

    ### Blogit Commands
    def list_comments(self):
        if vim.current.line.startswith('Status: '):
            p = BlogIt.WordPressCommentList.create_from_post(self.current_post)
            vim.command('enew')
            self.current_post = p
            try:
                p.getComments()
            except BlogIt.BlogItBug, e:
                p.init_vim_buffer()
                vim.command('setlocal nomodifiable')
                sys.stderr.write(unicode(e))
            else:
                p.init_vim_buffer()

    def list_edit(self):
        row, col = vim.current.window.cursor
        post = self.current_post.open_row(row)
        post.getPost()
        vim.command('bdelete')
        vim.command('enew')
        post.init_vim_buffer()
        self.current_post = post

    def vimcommand(doc_string, f=register_vimcommand):
        return partial(f, doc_string=doc_string)

    def get_vim_vars(self, blog_name=None):
        if blog_name is not None:
            return utils.VimVars(blog_name)
        else:
            return self.current_post.vim_vars

    @vimcommand(_("list all posts"))
    def command_ls(self, blog=None):
        vim_vars = self.get_vim_vars(blog)
        vim.command('botright new')
        try:
            self.current_post = blogclient.PostListing.create_new_post(vim_vars)
        except utils.PostListingEmptyException:
            vim.command('bdelete')
            sys.stderr.write("There are no posts.")

    @vimcommand(_("create a new post"))
    def command_new(self, blog=None):
        from blogit import blogpost

        vim_vars = self.get_vim_vars(blog)
        vim.command('enew')
        self.current_post = blogpost.AbstractBlogPost(vim_vars=vim_vars)
        self.current_post.create_new_post()

    @vimcommand(_("make this a blog post"))
    def command_this(self, blog=None):
        from blogit import blogpost

        if self.current_post is self.NO_POST:
            vim_vars = self.get_vim_vars(blog)
            self.current_post = blogpost.AbstractBlogPost(vim_vars = vim_vars)
            self.current_post.create_new_post(post_body=vim.current.buffer[:])
        else:
            sys.stderr.write("Already editing a post.")

    @vimcommand(_("edit a post"))
    def command_edit(self, id, blog=None):
        vim_vars = self.get_vim_vars(blog)
        try:
            id = int(id)
        except ValueError:
            if id in ['this', 'new']:
                self.command(id, blog)
                return
            sys.stderr.write(
                "'id' must be an integer value or 'this' or 'new'.")
            return

        post = BlogIt.WordPressBlogPost(id, vim_vars=vim_vars)
        try:
            post.getPost()
        except Fault, e:
            sys.stderr.write('Blogit Fault: ' + e.faultString)
        else:
            vim.command('enew')
            post.init_vim_buffer()
            self.current_post = post

    @vimcommand(_("edit a page"))
    def command_page(self, id, blog=None):
        # copied from command_edit
        vim_vars = self.get_vim_vars(blog)

        if id == 'new':
            vim.command('enew')
            post = BlogIt.WordPressPage.create_new_post(vim_vars)
        elif id == 'this':
            if self.current_post is not self.NO_POST:
                sys.stderr.write("Already editing a post.")
                return
            post = BlogIt.WordPressPage.create_new_post(vim_vars,
                                                        vim.buffer[:])
        else:
            try:
                id = int(id)
            except ValueError:
                sys.stderr.write("'id' must be an integer value or 'new'.")
                return
            post = BlogIt.WordPressPage(id, vim_vars=vim_vars)
            try:
                post.getPost()
            except Fault, e:
                sys.stderr.write('Blogit Fault: ' + e.faultString)
                return
            vim.command('enew')
            post.init_vim_buffer()
            self.current_post = post

    @vimcommand(_("save article"))
    def command_commit(self):
        p = self.current_post
        p.send(vim.current.buffer[:])
        p.refresh_vim_buffer()

    @vimcommand(_("publish article"))
    def command_push(self):
        p = self.current_post
        p.send(vim.current.buffer[:], push=1)
        p.refresh_vim_buffer()

    @vimcommand(_("unpublish article (save as draft)"))
    def command_unpush(self):
        p = self.current_post
        p.send(vim.current.buffer[:], push=0)
        p.refresh_vim_buffer()

    @vimcommand(_("remove a post"))
    def command_rm(self, id):
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

    @vimcommand(_("update and list tags and categories"))
    def command_tags(self):
        p = self.current_post
        username, password = p.vim_vars.blog_username, p.vim_vars.blog_password
        multicall = xmlrpclib.MultiCall(p.client)
        multicall.wp.getCategories('', username, password)
        multicall.wp.getTags('', username, password)
        categories, tags = tuple(multicall())
        tags = [BlogIt.enc(tag['name']) for tag in tags]
        categories = [BlogIt.enc(cat['categoryName']) for cat in categories]
        vim.command('let s:used_tags = %s' % BlogIt.to_vim_list(tags))
        vim.command('let s:used_categories = %s' %
                    BlogIt.to_vim_list(categories))
        sys.stdout.write('\n \n \nCategories\n==========\n \n' +
                         ', '.join(categories))
        sys.stdout.write('\n \n \nTags\n====\n \n' + ', '.join(tags))

    @vimcommand(_("preview article in browser"))
    def command_preview(self):
        p = self.current_post
        if isinstance(p, BlogIt.CommentList):
            raise utils.NoPostException
        if self.prev_file is None:
            self.prev_file = tempfile.mkstemp('.html', 'blogit')[1]
            f = open(self.prev_file, 'w')
            f.write(p.read_post(vim.current.buffer[:])[p.POST_BODY])
            f.flush()
            f.close()
            webbrowser.open(self.prev_file)

    @vimcommand(_("display this notice"))
    def command_help(self):
        sys.stdout.write("Available commands:\n")
        for f in self.vimcommand_help:
            sys.stdout.write('   ' + f)

    # needed for testing. Prevents being used as a decorator if it isn't at
    # the end.
    register_vimcommand = staticmethod(register_vimcommand)

if doctest is not None:
    blogit = BlogIt()
