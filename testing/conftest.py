#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Copyright (C) 2009 Romain Bignon
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

import py.test
from functools import partial
from minimock import Mock
try:
    from . import mybloglogin
except ImportError:
    mybloglogin = None


pytest_plugins = ['doctest', 'monkeypatch']
collect_ignore = ['conftest.py', 'mybloglogin.py', '__init__.py']


def pytest_addoption(parser):
    group = parser.getgroup('')
    group.addoption('-A', dest='acceptance', action='store_true',
                    help='run (slow) acceptance tests')


def pytest_configure(config):
    config.option.doctestmodules = not config.option.doctestmodules


def assure_acceptence(config):
    if not config.option.acceptance:
        py.test.skip('specify -A to run acceptance tests')
    elif mybloglogin is None:
        py.test.skip('no blog login configured')


def pytest_funcarg__accept_vim_vars(request):
    blogconfig = request.getfuncargvalue('accept_blogconfig')
    acceptance_vim_vars = Mock('VimVars')
    vim_vars.blog_url = blogconfig.blog_url
    vim_vars.blog_username = blogconfig.username
    vim_vars.blog_password = blogconfig.password
    vim_vars.blog_name = blogconfig.blog_name
    return vim_vars


class BlogConfig(object):

    def __init__(self, blog_url, username, password, blog_name,
                 postsource=False):
        self.blog_url = blog_url
        self.username = username
        self.password = password
        self.blog_name = blog_name
        self.postsource = postsource


def pytest_generate_tests(metafunc):
    if not 'accept_blogconfig' in metafunc.funcargnames:
        return
    assure_acceptence(metafunc.config)
    f_prefix = 'blog_login__'
    account_generators = [f_name for f_name in dir(mybloglogin)
                                        if f_name.startswith(f_prefix)]
    for f_name in account_generators:
        f_basename = f_name.replace(f_prefix, '')
        constructor = partial(BlogConfig, blog_name=f_basename)
        blogconfig = getattr(mybloglogin, f_name)(constructor)
        metafunc.addcall({'accept_blogconfig': blogconfig}, id=f_basename)
