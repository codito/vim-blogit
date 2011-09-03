#!/usr/bin/env python

import json
import re
from base64 import b64encode
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

class PosterousBlogClient(blogclient.AbstractBlogClient):
    # {0} = api group e.g sites; {1} = site_id e.g. stdin
    api_url_format = "http://posterous.com/api/2/{0}/{1}"
    blogid = None

    def create_new_post(self, post_content=[''], post_type=None):
        return blogpost.PosterousBlogPost.create_new_post(self.vim_vars, post_content)

    def get_date_format(self):
        return '%Y/%m/%d %H:%M:%S %z'

    def get_posts(self, post_type):
        """Possible post types: Text
        Supported post types in Posterous: Text, Photo, Quote, Link, Chat, Audio, Video.
        """
        data = None
        if post_type == "text":
            params = {}
            data = self._posterous_http_get(self.api_url_format.format("sites", self._get_blogid()) +
                                          "/posts", params)
        return data

    def _get_authentication(self):
        """Gets the base64 encoded auth string"""
        return "Basic " + b64encode(self.vim_vars.blog_username + ":" + self.vim_vars.blog_password)

    def _get_blogid(self):
        if self.blogid is None:
            m = re.match("^.*://(.*)\.posterous.com*$", self.vim_vars.blog_url, re.DOTALL)
            self.blogid = m.group(1)
        return self.blogid

    def _get_post_group_types(self):
        return [PosterousPostListingPosts]

    def _posterous_http_get(self, url, params = {}):
        params["api_token"] = self.vim_vars.blog_apitoken
        server_response = self._http_get_request(url, params, { "Authorization":
                                                               self._get_authentication() })
        post_data = json.loads(server_response)
        return post_data


class PosterousPostListingPosts(blogclient.AbstractPostListingSource):

    def __init__(self, vim_vars):
        super(PosterousPostListingPosts, self).__init__(('id', 'display_date', 'title'),
                                                     vim_vars)

    def client_call__getPost(self, client):
        return client.get_posts("text")

    def open_row(self, n):
        #id = self.post_data[n]['id']
        raise NotImplementedError
        #return PosterousPage(id, vim_vars=self.vim_vars)


class PosterousBlogPost(blogpost.BlogPost):

    def __init__(self, blog_post_id, post_data={}, meta_data_dict=None,
                 headers=None, post_body='body', vim_vars=None,
                 client=None):
        if meta_data_dict is None:
            meta_data_dict = {'Id': 'id',
                              'Subject': 'title',
                              'Tags': 'tags',
                              'Date_AS_DateTime': 'display_date',
                              'Draft': 'draft',
                              'Private': 'is_private',
                              'Autopost': 'autopost',
                             }

        super(PosterousBlogPost, self).__init__(blog_post_id, post_data,
                                                meta_data_dict, headers,
                                                post_body, vim_vars)
        if client is None:
            client = blogclient.AbstractBlogClient(self.vim_vars)
        self.client = client

    def do_send(self, push=None):
        """ Send post to server.

        >>> mock('sys.stderr')
        >>> p = PosterousBlogPost(42,
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

        >>> p = PosterousBlogPost(42)
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
        >>> PosterousBlogPost.create_new_post(utils.VimVars())     #doctest: +ELLIPSIS
        time data '' does not match format '%Y%m%dT%H:%M:%S'
        <blogit.clients.wordpress.PosterousBlogPost object at 0x...>
        >>> minimock.restore()
        """
        b = cls('', post_data={'draft': 'true', 'body': '', 'id': '',
                               'tags': '', 'is_private': 'false', 'title': '',
                               'autopost': 'false'},
                vim_vars=vim_vars)
        b.init_vim_buffer()
        if body_lines != ['']:
            vim.current.buffer[-1:] = body_lines
        return b
