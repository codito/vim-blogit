#!/usr/bin/env python

import json
import re
import sys
from base64 import b64encode
from xmlrpclib import DateTime
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

    def create_post(self, post_data={}):
        """Creates a new blog post. Returns the post id. Params:
            - post_data: dictionary of key, value to be sent to server
        """
        data = self._posterous_http_post(self.api_url_format.format("sites", self._get_blogid()) +
                                        "/posts", post_data)
        return str(data['id'])

    def edit_post(self, post_id, post_data={}):
        """Edits and saves a blog post. Params:
            - post_id: the Id of the post being edited
            - post_data: dictionary of key, value to be sent to server
        """
        raise NotImplementedError("edit_post is not implemented in %s" % str(self))

    def get_date_format(self):
        return '%Y/%m/%d %H:%M:%S %z'

    def get_post(self, post_id):
        """Gets a blog post. Returns the dictionary of key, values for this post. Params:
            - post_id: the Id of the post being edited
        """
        data = self._posterous_http_get(self.api_url_format.format("sites", self._get_blogid()) +
                                        "/posts/" + post_id)
        return data

    def get_posts(self, post_type):
        """Possible post types: Text
        Supported post types in Posterous: Text
        """
        data = None
        if post_type == "text":
            params = {}
            data = self._posterous_http_get(self.api_url_format.format("sites", self._get_blogid()) +
                                          "/posts", params)
        return data

    def get_tags(self):
        """Gets a blog's tags. Returns the dictionary of key, values for this post. Params:
            - post_id: the Id of the post being edited
        """
        data = self._posterous_http_get(self.api_url_format.format("sites", self._get_blogid()) +
                                        "/tags")
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
        server_response = self._http_get_request(url, params, {"Authorization":
                                                               self._get_authentication() })
        post_data = json.loads(server_response)
        return post_data

    def _posterous_http_post(self, url, params = {}):
        params["api_token"] = self.vim_vars.blog_apitoken
        server_response = self._http_post_request(url, params, {"Authorization":
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


class PosterousBlogPost(blogpost.AbstractBlogPost):

    def __init__(self, vim_vars=None, content=[''], client=None):
        super(PosterousBlogPost, self).__init__(vim_vars)
        if client is None:
            client = blogclient.AbstractBlogClient(vim_vars)
        self.client = client

    def get_headers(self):
        """Returns the metadata dictionary mapping for the server. Must be implemented by client."""
        return ['Id',
                'Date',
                'Draft',    # True if the post is a draft. Default: True
                'Private',  # True if the post should be private. Default: False
                'Autopost', # True if you'd like posterous to post to twitter etc.. Default: False
                'Subject',
                'Tags'
               ]

    def get_meta_data_dict(self):
        """Returns the metadata dictionary mapping for the server. Must be implemented by client."""
        return {'Id': 'id',
                'Date': 'post[display_date]',
                'Draft': 'draft',
                'Private': 'post[is_private]',
                'Autopost': 'post[autopost]',
                'Subject': 'post[title]',
                'Tags': 'post[tags]',
                'Body': 'post[body]'
               }

    def get_post_data(self):
        """Returns the post_data mapping for the server. Must be implemented by client."""
        return {'id': '',
                'post[display_date]': '',
                'draft': 'True',
                'post[is_private]': 'False',
                'post[autopost]': 'False',
                'post[title]': '',
                'post[tags]': '',
                'post[body]': '',
               }

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
        def sendPost(push=0):
            """ Unify newPost and editPost from the metaWeblog API. """
            if self.BLOG_POST_ID == '':
                self.BLOG_POST_ID = self.client.create_post(self.post_data)
            else:
                self.client.edit_post(self.BLOG_POST_ID, self.post_data)

        if push == 0 or self.get_server_var__post_status() == 'draft':
            self.set_server_var__Date_AS_DateTime(DateTime())
            self.new_post_data['post[draft]'] = 'True'
        self.post_data.update(self.new_post_data)
        
        try:
            sendPost(push)
        except Exception, e:
            sys.stderr.write(e.message)
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
        d = self.client.get_post(self.BLOG_POST_ID)
        if vim.eval('s:used_tags == []') == '1':
            tags = self.client.get_tags()
            vim.command('let s:used_tags = %s' % utils.to_vim_list( [tag['name'] for tag in tags]))
        self.post_data = d
