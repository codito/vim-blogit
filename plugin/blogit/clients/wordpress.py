#!/usr/bin/env python

import sys
import xmlrpclib
from xmlrpclib import DateTime, Fault
from blogit import blogclient, blogpost, utils

try:
    import vim
except ImportError:
    # Used outside of vim (for testing)
    import doctest, minimock
    from minimock import Mock, mock
    from blogit.tests.mock_vim import vim
else:
    doctest = None

class MetaWeblogBlogClient(blogclient.AbstractBlogClient):
    def get_posts(self, post_type):
        """Possible post types:
            - MetaWeblog: Text (aka normal blog post)
        """
        data = None
        if post_type == "text":
            data = self._get_client_instance().metaWeblog.getRecentPosts('',
                                                                         self.vim_vars.blog_username,
                                                                         self.vim_vars.blog_password)
        return data

    def _get_client_instance(self):
        if self.client_instance is None:
            self.client_instance = xmlrpclib.ServerProxy(self.vim_vars.blog_url)
        return self.client_instance

    def _get_post_group_types(self):
        return [MetaWeblogPostListingPosts]


class WordPressBlogClient(MetaWeblogBlogClient):
    def create_new_post(self, post_content=[''], post_type=None):
        return WordPressBlogPost.create_new_post(self.vim_vars, post_content)

    def get_posts(self, post_type):
        """Possible post types:
            - MetaWeblog: Text (aka normal blog post)
            - Wordpress: [MetaWeblog], Page
        """
        data = None
        if post_type == "text":
            data = self._get_client_instance().metaWeblog.getRecentPosts('',
                                                                         self.vim_vars.blog_username,
                                                                         self.vim_vars.blog_password)
        elif post_type == "page":
            data = self._get_client_instance().wp.getPageList('',
                                                              self.vim_vars.blog_username,
                                                              self.vim_vars.blog_password)
        return data

    def _get_post_group_types(self):
        return [MetaWeblogPostListingPosts, WordPressPostListingPages]


class MetaWeblogPostListingPosts(blogclient.AbstractPostListingSource):
    def __init__(self, vim_vars):
        super(MetaWeblogPostListingPosts, self).__init__(('postid', 'date_created_gmt', 'title'),
                                                         vim_vars)

    def client_call__getPost(self, client):
        return client.get_posts("text")

    def open_row(self, n):
        id = self.post_data[n]['postid']
        return WordPressBlogPost(id, vim_vars=self.vim_vars)


class WordPressPostListingPages(blogclient.AbstractPostListingSource):
    def __init__(self, vim_vars):
        super(WordPressPostListingPages, self).__init__(('page_id', 'dateCreated', 'page_title'),
                                                        vim_vars)

    def client_call__getPost(self, client):
        return client.get_posts("page")

    def open_row(self, n):
        id = self.post_data[n]['page_id']
        return WordPressPage(id, vim_vars=self.vim_vars)


class WordPressBlogPost(blogpost.BlogPost):

    def __init__(self, blog_post_id, post_data={}, meta_data_dict=None,
                 headers=None, post_body='description', vim_vars=None,
                 client=None):
        if meta_data_dict is None:
            meta_data_dict = {'From': 'wp_author_display_name',
                              'Id': 'postid',
                              'Subject': 'title',
                              'Categories_AS_list': 'categories',
                              'Tags': 'mt_keywords',
                              'Date_AS_DateTime': 'date_created_gmt',
                              'Status_AS_dict': 'blogit_status',
                             }

        super(WordPressBlogPost, self).__init__(blog_post_id, post_data,
                                                meta_data_dict, headers,
                                                post_body, vim_vars)
        if client is None:
            client = xmlrpclib.ServerProxy(self.vim_vars.blog_url)
        self.client = client

    def do_send(self, push=None):
        """ Send post to server.

        >>> mock('sys.stderr')
        >>> p = WordPressBlogPost(42,
        ...         {'post_status': 'new', 'postid': 42})
        >>> mock('p.client'); mock('p.getPost'); mock('p.display')
        >>> mock('vim.mocked_eval', tracker=None)
        >>> p.send(['', 'text'])    #doctest: +NORMALIZE_WHITESPACE
        Called p.client.metaWeblog.editPost( 42, 'user', 'password',
                {'post_status': 'new', 'postid': 42,
                 'description': 'text'}, 0)
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

        if push == 0 or self.get_server_var__post_status() == 'draft':
            self.set_server_var__Date_AS_DateTime(DateTime())
        self.post_data.update(self.new_post_data)
        push_dict = {0: 'draft', 1: 'publish',
                     None: self.post_data['post_status']}
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

        >>> p = WordPressBlogPost(42)
        >>> p.getPost()    #doctest: +NORMALIZE_WHITESPACE
        Called xmlrpclib.MultiCall(<ServerProxy for example.com/RPC2>)
        Called multicall.metaWeblog.getPost(42, 'user', 'password')
        Called multicall.wp.getCommentCount('', 'user', 'password', 42)
        Called vim.mocked_eval('s:used_tags == [] ||
                                s:used_categories == []')
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
            vim.command('let s:used_tags = %s' % utils.to_vim_list( [tag['name'] for tag in tags]))
            vim.command('let s:used_categories = %s' %
                        utils.to_vim_list([cat['categoryName'] for cat in categories]))
        else:
            d, comments = tuple(multicall())
        comments['post_status'] = d['post_status']
        d['blogit_status'] = comments
        self.post_data = d

    @classmethod
    def create_new_post(cls, vim_vars, body_lines=['']):
        """
        >>> mock('vim.command', tracker=None)
        >>> mock('vim.mocked_eval', tracker=None)
        >>> WordPressBlogPost.create_new_post(utils.VimVars())     #doctest: +ELLIPSIS
        time data '' does not match format '%Y%m%dT%H:%M:%S'
        <blogit.clients.wordpress.WordPressBlogPost object at 0x...>
        >>> minimock.restore()
        """
        b = cls('', post_data={'post_status': 'draft', 'description': '', 'wp_author_display_name':
                               vim_vars.blog_username, 'postid': '', 'categories': [],
                               'mt_keywords': '', 'date_created_gmt': '', 'title': '',
                               'Status_AS_dict': {'awaiting_moderation': 0, 'spam': 0,
                                                  'post_status': 'draft', 'total_comments': 0, }},
                vim_vars=vim_vars)
        b.init_vim_buffer()
        if body_lines != ['']:
            vim.current.buffer[-1:] = body_lines
        return b


class WordPressPage(blogpost.Page):

    def __init__(self, blog_post_id, post_data={}, meta_data_dict=None,
                 headers=None, post_body='description', vim_vars=None,
                 client=None):
        if meta_data_dict is None:
            meta_data_dict = {'From': 'wp_author_display_name',
                              'Id': 'page_id',
                              'Subject': 'title',
                              'Categories_AS_list': 'categories',
                              'Date_AS_DateTime': 'dateCreated',
                              'Status_AS_dict': 'blogit_status',
                              'Page': 'wp_slug',
                              'Status_post': 'page_status',
                             }
        super(WordPressPage, self).__init__(blog_post_id, post_data, meta_data_dict, headers,
                                            post_body, vim_vars)
        if client is None:
            client = xmlrpclib.ServerProxy(self.vim_vars.blog_url)
        self.client = client

    def do_send(self, push=None):
        if push == 1:
            self.set_server_var__Date_AS_DateTime(DateTime())
            self.set_server_var__Status_post('publish')
        elif push == 0:
            self.set_server_var__Date_AS_DateTime(DateTime())
            self.set_server_var__Status_post('draft')
        self.post_data.update(self.new_post_data)
        if self.BLOG_POST_ID == '':
            self.BLOG_POST_ID = self.client.wp.newPage('',
                                             self.vim_vars.blog_username,
                                             self.vim_vars.blog_password,
                                             self.post_data)
        else:
            self.client.wp.editPage('', self.BLOG_POST_ID,
                                    self.vim_vars.blog_username,
                                    self.vim_vars.blog_password,
                                    self.post_data)
        self.getPost()

    def getPost(self):
        username = self.vim_vars.blog_username
        password = self.vim_vars.blog_password

        multicall = xmlrpclib.MultiCall(self.client)
        multicall.wp.getPage('', self.BLOG_POST_ID, username, password)
        multicall.wp.getCommentCount('', username, password,
                                     self.BLOG_POST_ID)
        d, comments = tuple(multicall())
        comments['post_status'] = d['page_status']
        d['blogit_status'] = comments
        self.post_data = d

    @classmethod
    def create_new_post(cls, vim_vars, body_lines=['']):
        """
        >>> mock('vim.command', tracker=None)
        >>> mock('vim.mocked_eval', tracker=None)
        >>> WordPressPage.create_new_post(utils.VimVars())     #doctest: +ELLIPSIS
        time data '' does not match format '%Y%m%dT%H:%M:%S'
        <blogit.clients.wordpress.WordPressPage object at 0x...>
        >>> minimock.restore()
        """
        b = cls('', post_data={'page_status': 'draft', 'description': '',
                'wp_author_display_name': vim_vars.blog_username,
                'page_id': '', 'wp_slug': '', 'title': '',
                'categories': [], 'dateCreated': '',
                'Status_AS_dict': {'awaiting_moderation': 0, 'spam': 0,
                                   'post_status': 'draft',
                                   'total_comments': 0}},
                vim_vars=vim_vars)
        b.init_vim_buffer()
        if body_lines != ['']:
            vim.current.buffer[-1:] = body_lines
        return b
