#!/usr/bin/env python

import urllib, urllib2
from xmlrpclib import DateTime
from blogit import utils

try:
    import vim
except ImportError:
    # Used outside of vim (for testing)
    import doctest, minimock
    from minimock import Mock, mock
    from tests.mock_vim import vim
else:
    doctest = None

class AbstractBlogClient(object):
    """Abstracts client specific behavior. Currently three types of clients are supported:
        - MetaWeblog (Implementation: xmlrpc.metaWeblog). See MetaWebblogBlogClient.
        - Wordpress (Implementation: xmlrpc.metaWeblog + xmlrpc.wp). See WordPressBlogClient.
        - Tumblr (Implementation: tumblr REST api). See TumblrBlogClient.
        - Posterous (Implementation: posterous REST api). See PosterousBlogClient.
    """

    def __new__(cls, vim_vars=None):
        """Factory pattern to choose the appropriate blog client implementation based on
        variables.
        """
        from blogit.clients import posterous, wordpress, tumblr

        if (vim_vars == None):
            vim_vars = utils.VimVars()
        cls.vim_vars = vim_vars
        cls.client_instance = None
        blog_type = wordpress.MetaWeblogBlogClient
        if cls.vim_vars.blog_clienttype == "wordpress":
            blog_type = wordpress.WordPressBlogClient
        if cls.vim_vars.blog_clienttype == "tumblr":
            blog_type = tumblr.TumblrBlogClient
        elif cls.vim_vars.blog_clienttype == "posterous":
            blog_type = posterous.PosterousBlogClient
        return object.__new__(blog_type)

    def create_post(self, post_data={}):
        """Creates a new blog post. Returns the post id. Params:
            - post_data: dictionary of key, value to be sent to server
        Must be implemented by clients."""
        raise NotImplementedError("create_post is not implemented in %s" % str(self))

    def edit_post(self, post_id, post_data={}):
        """Edits and saves a blog post. Params:
            - post_id: the Id of the post being edited
            - post_data: dictionary of key, value to be sent to server
        Must be implemented by clients."""
        raise NotImplementedError("edit_post is not implemented in %s" % str(self))

    def get_date_format(self):
        """Returns the date format for Posts, Pages etc. Default format is suitable for
        Metaweblog and Wordpress.
        """
        return '%Y%m%dT%H:%M:%S'

    def get_post(self, post_id):
        """Gets a blog post. Returns the dictionary of key, values for this post. Params:
            - post_id: the Id of the post being edited
        Must be implemented by clients."""
        raise NotImplementedError("get_post is not implemented in %s" % str(self))

    def get_post_groups(self):
        """Returns the post types supported by this blog client."""
        return [group(self.vim_vars) for group in self._get_post_group_types()]

    def get_posts(self, post_type):
        """Gets the posts of type <post_type> from the blog. Must be implemented by derived
        clients.
        """
        raise NotImplementedError("get_posts is not implemented in %s" % str(self))

    def get_tags(self):
        """Gets a blog's tags. Returns the dictionary of key, values for this post. Params:
            - post_id: the Id of the post being edited
        Must be implemented by clients."""
        raise NotImplementedError("get_tags is not implemented in %s" % str(self))

    def _get_post_group_types(self):
        """Gets a tuple of types of posts supported by the blog. Must be implemented by derived
        clients.
        """
        raise NotImplementedError("_get_post_group_types is not implemented in %s" % str(self))

    def _http_get_request(self, url, params, headers={}):
        print "\nGET: "
        print params
        data = urllib.urlencode(params)
        url = url + "?" + data
        req = urllib2.Request(url)
        return self._http_request(req, headers)

    def _http_post_request(self, url, params, headers={}):
        print "\nPOST:"
        print params
        data = urllib.urlencode(params)
        req = urllib2.Request(url, data)
        return self._http_request(req, headers)

    def _http_request(self, req, headers={}):
        [req.add_header(k, v) for k, v in headers.iteritems()]
        try:
            ret = urllib2.urlopen(req)
            x = ret.read()
            print x
            return x
        except urllib2.HTTPError, e:
            print e.read()
            raise e

class AbstractBufferIO(object):
    """Wraps common IO interactions on a vim buffer."""

    def display(self):
        """Returns the lines in buffer after conversion using meta_data_dict/headers."""
        raise NotImplementedError("Must be implemented by derived class.")

    def init_vim_buffer(self):
        vim.command('setlocal encoding=utf-8')
        self.refresh_vim_buffer()

    def refresh_vim_buffer(self):
        vim.current.buffer[:] = [utils.encode_to_utf(line) for line in self.display()]
        vim.command('setlocal nomodified')

    def read_post(self, lines):
        raise NotImplementedError("Must be implemented by derived class.")

    def send(self, lines=[], push=None):
        self.read_post(lines)
        self.do_send(push)

    def do_send(self, push=None):
        raise utils.NoPostException


class PostListing(AbstractBufferIO):
    """Represents a vim buffer that lists posts on remote server."""
    POST_TYPE = 'list'

    def __init__(self, vim_vars=None, client=None):
        if vim_vars is None:
            vim_vars = utils.VimVars()
        self.vim_vars = vim_vars
        if client is None:
            client = AbstractBlogClient(self.vim_vars)
        self.client = client
        self.post_data = None
        self.row_groups = self.client.get_post_groups()

    @classmethod
    def create_new_post(cls, vim_vars, body_lines=['']):
        b = cls(vim_vars=vim_vars)
        b.getPost()
        b.init_vim_buffer()
        return b

    def init_vim_buffer(self):
        super(PostListing, self).init_vim_buffer()
        vim.command('setlocal buftype=nofile bufhidden=wipe nobuflisted ' +
                'noswapfile syntax=blogsyntax nomodifiable nowrap')
        vim.current.window.cursor = (2, 0)
        vim.command('nnoremap <buffer> <enter> :Blogit! list_edit<cr>')
        vim.command('nnoremap <buffer> gf :Blogit! list_edit<cr>')

    def display(self):
        """ Yields the rows of a table displaying the posts (at least one).

        >>> p = PostListing()
        >>> p.display().next()       #doctest: +ELLIPSIS
        Traceback (most recent call last):
          [...]
        PostListingEmptyException
        >>> p.row_groups[0].post_data = [ {'postid': '1',
        ...     'date_created_gmt': DateTime('20090628T17:38:58'),
        ...     'title': 'A title'} ]
        >>> list(p.display())    #doctest: +NORMALIZE_WHITESPACE
        ['ID    Date        Title',
        u' 1    06/28/09    A title']
        >>> p.row_groups[0].post_data = [{'postid': id,
        ...     'date_created_gmt': DateTime(d), 'title': t}
        ...     for id, d, t in zip(( '7', '42' ),
        ...         ( '20090628T17:38:58', '20100628T17:38:58' ),
        ...         ( 'First Title', 'Second Title' )
        ...     )]
        >>> list(p.display())    #doctest: +NORMALIZE_WHITESPACE
        ['ID    Date        Title',
        u' 7    06/28/09    First Title',
        u'42    06/28/10    Second Title']

        """
        for row_group in self.row_groups:
            if not row_group.is_empty:
                break
        else:
            raise utils.PostListingEmptyException
        id_column_width = max(2, *[p.min_id_column_width
                                        for p in self.row_groups])
        yield "ID    %sDate%sTitle" % (' ' * (id_column_width - 2),
                ' ' * len(utils.DateTime_to_str(DateTime(), '%x')))
        format = '%%%dd    %%s    %%s' % id_column_width
        for row_group in self.row_groups:
            for post_id, date, title in row_group.rows_data():
                yield format % (int(post_id),
                                utils.DateTime_to_str(date, '%x', self.client.get_date_format()),
                                title)

    def getPost(self):
        #FIXME is it possible to use multicalls with current refactoring?
        for row_group in self.row_groups:
            row_group.getPost(self.client)

    def open_row(self, n):
        n -= 2    # Table header & vim_buffer lines start at 1
        for row_group in self.row_groups:
            if n < len(row_group.post_data):
                return row_group.open_row(n)
            else:
                n -= len(row_group.post_data)


class AbstractPostListingSource(object):
    """Wraps the client calls to get the list of posts. Each BlogClient implementation must provide
    the appropriate functionality."""

    def __init__(self, id_date_title_tags, vim_vars):
        self.id_date_title_tags = id_date_title_tags
        self.vim_vars = vim_vars
        self.post_data = []

    def client_call__getPost(self, client):
        """Must be implemented by inherited classes"""
        raise NotImplementedError

    def getPost(self, client):
        self.post_data = self.client_call__getPost(client)

    @property
    def is_empty(self):
        return len(self.post_data) == 0

    @property
    def min_id_column_width(self):
        return max(-1, -1,    # Work-around max(-1, *[]) not-iterable.
                   *[len(str(p[self.id_date_title_tags[0]]))
                                            for p in self.post_data])

    def rows_data(self):
        post_id, date, title = self.id_date_title_tags
        for p in self.post_data:
            yield (p[post_id], p[date], p[title])
