#!/usr/bin/env python

from xmlrpclib import DateTime
from locale import getpreferredencoding
from time import strptime, strftime

try:
    import vim
except ImportError:
    # Used outside of vim (for testing)
    import doctest, minimock
    from minimock import Mock, mock
    from tests.mock_vim import vim
else:
    doctest = None

class VimVars(object):
    """ Wraps the configuration for blogit in passwords.vim file. """
    def __init__(self, blog_name=None):
        if blog_name is None:
            blog_name = self.vim_blog_name
        self.blog_name = blog_name

    @property
    def blog_apitoken(self):
        """Posterous requires an api_token."""
        return self.vim_variable('apitoken')

    @property
    def blog_clienttype(self):
        """
        >>> mock('VimVars.vim_variable')
        >>> VimVars().blog_clienttype
        Called VimVars.vim_variable('b:blog_name', prefix=False)
        Called VimVars.vim_variable('blog_name', prefix=False)
        Called VimVars.vim_variable('clienttype')
        'wordpress'
        >>> mock('VimVars.vim_variable', returns_iter=[ 'blog_name', 'xyz' ])
        >>> VimVars().blog_clienttype
        Called VimVars.vim_variable('b:blog_name', prefix=False)
        Called VimVars.vim_variable('clienttype')
        'xyz'
        >>> minimock.restore()
        """
        client_type = self.vim_variable('clienttype')
        if client_type is None:
            client_type = "wordpress"
        return client_type

    @property
    def blog_username(self):
        return self.vim_variable('username')

    @property
    def blog_password(self):
        return self.vim_variable('password')

    @property
    def blog_url(self):
        """
        >>> mock('vim.eval', returns_iter=[ '0', '0', '1', 'http://example.com/' ])
        >>> VimVars().blog_url
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
    def vim_blog_name(self):
        for var_name in ('b:blog_name', 'blog_name'):
            var_value = self.vim_variable(var_name, prefix=False)
            if var_value is not None:
                return var_value
        return 'blogit'

    def vim_variable(self, var_name, prefix=True):
        """ Simplify access to vim-variables. """
        if prefix:
            var_name = '_'.join((self.blog_name, var_name))

        if vim.eval("exists('%s')" % var_name) == '1':
            return vim.eval('%s' % var_name)
        else:
            return None

    def export_blog_name(self):
        vim.command("let b:blog_name='%s'" % self.blog_name)

    def export_post_type(self, post):
        vim.command("let b:blog_post_type='%s'" % post.POST_TYPE)

# Error handling
class BlogItException(Exception):
    pass

class NoPostException(BlogItException):
    pass

class BlogItBug(BlogItException):
    pass

class PostListingEmptyException(BlogItException):
    pass

class FilterException(BlogItException):
    def __init__(self, message, input_text, filter):
        self.message = "Blogit: Error happend while filtering with:" + \
                filter + '\n' + message
        self.input_text = input_text
        self.filter = filter

# Utility functions
def encode_to_utf(text):
    """ Helper function to encode ascii or unicode strings. Used when communicating with Vim buffers
    and commands.""" 
    try:
        return text.encode('utf-8')
    except UnicodeDecodeError:
        return text

def to_vim_list(L):
    """ Helper function to encode a List for ":let L = [ 'a', 'b' ]" """
    L = ['"%s"' % encode_to_utf(item).replace('\\', '\\\\')
         .replace('"', r'\"') for item in L]
    return '[ %s ]' % ', '.join(L)

def str_to_DateTime(text='', format='%c'):
    if text == '':
        return DateTime('')
    else:
        try:
            text = text.encode(getpreferredencoding())
        except UnicodeDecodeError:
            text = text.decode('utf-8').encode(getpreferredencoding())
        # FIXME TZ info is lost, %z is not really portable
        if format.endswith('%z'):
            text = text[:-6]
            format = format[:-3]
        text = strptime(text, format)
    return DateTime(strftime('%Y%m%dT%H:%M:%S', text))

def DateTime_to_str(date, output_format='%c', input_format='%Y%m%dT%H:%M:%S'):
    try:
        # FIXME TZ info is lost, %z is not really portable
        if input_format.endswith('%z'):
            date = date[:-6]
            input_format = input_format[:-3]
        return unicode(strftime(output_format, strptime(str(date), input_format)),
                       getpreferredencoding(), 'ignore')
    except ValueError, e:
        print e
        return ''
