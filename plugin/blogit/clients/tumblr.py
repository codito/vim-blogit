#!/usr/bin/env python

import json
import re
from blogit import blogclient, blogpost

class TumblrBlogClient(blogclient.AbstractBlogClient):
    def create_new_post(self, post_content=[''], post_type=None):
        return blogpost.TumblrBlogPost.create_new_post(self.vim_vars, post_content)

    def get_date_format(self):
        return '%Y-%m-%d %H:%M:%S %Z'

    def get_posts(self, post_type):
        """Possible post types: Text
        Supported post types in Tumblr: Text, Photo, Quote, Link, Chat, Audio, Video.
        """
        data = None
        if post_type == "text":
            params = {}
            params["type"] = "text"
            data = self._tumblr_http_post(self.vim_vars.blog_url + "/api/read/json", params)
        return data

    def _get_post_group_types(self):
        return [TumblrPostListingPosts]

    def _tumblr_http_post(self, url, params = {}):
        params["email"] = self.vim_vars.blog_username
        params["password"] = self.vim_vars.blog_password
        params["generator"] = "vim-blogit"

        server_response = self._http_post_request(url, params)
        m = re.match("^.*?({.*}).*$", server_response, re.DOTALL | re.MULTILINE)
        post_data = json.loads(m.group(1))["posts"]
        return post_data


class TumblrPostListingPosts(blogclient.AbstractPostListingSource):

    def __init__(self, vim_vars):
        super(TumblrPostListingPosts, self).__init__(('id', 'date-gmt', 'regular-title'),
                                                     vim_vars)

    def client_call__getPost(self, client):
        return client.get_posts("text")

    def open_row(self, n):
        #id = self.post_data[n]['id']
        raise NotImplementedError
        #return WordPressPage(id, vim_vars=self.vim_vars)


class TumblrBlogPost(blogpost.BlogPost):
    pass
