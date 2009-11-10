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

""" Tests to narrow `#147`_ down. Will be integrated into other tests once
debugging is done.

.. _#147: http://symlink.me/issues/show/147
"""
from __future__ import with_statement
from subprocess import Popen, PIPE
import hashlib
from blogit import BlogIt
import mock_vim
from minimock import Mock
import py


def test_pandoc(markdown_file):
    pandoc_process = Popen(['pandoc', '--from=markdown', '--to=html',
                            '--no-wrap', markdown_file[0]],
                           stdout=PIPE, stderr=PIPE)
    pandoc_process.wait()
    # pandoc's magic can't handle this directly in the assert.
    pandoc_err = pandoc_process.stderr.read()
    pandoc_out = pandoc_process.stdout.read()
    assert pandoc_err == ''
    assert pandoc_process.returncode == 0
    with open(markdown_file[1]) as f_html:
        expected_out = f_html.read()
        assert pandoc_out == expected_out


def _test_read_post_body_with_pandoc(markdown, blog_post, post_header_line):
    markdown_code, html_code, convert_code = markdown
    setattr(blog_post.vim_vars, blog_post.vim_vars.blog_name + '_format',
            convert_code)
    assert blog_post.vim_vars.a_blog_name_format == convert_code
    blogit_format_value = blog_post.vim_vars.vim_variable('format')
    assert blogit_format_value == convert_code

    buffer_lines = [post_header_line, ''] + markdown_code.splitlines()
    post_body = blog_post.read_post(buffer_lines)[blog_post.POST_BODY]
    assert post_body == html_code


def test_read_post_body(markdown, blog_post, post_header_line):
    markdown_code, html_code, convert_code = markdown

    buffer_lines = [post_header_line, ''] + markdown_code.splitlines()
    post_body = blog_post.read_post(buffer_lines)[blog_post.POST_BODY]
    assert post_body == markdown_code.strip()


def pytest_funcarg__markdown_file(request):
    return ('t.mkd', 't.html')


def pytest_funcarg__blog_post(request):
    vim_vars = request.getfuncargvalue('mocked_vim_vars')
    monkeypatch = request.getfuncargvalue('monkeypatch')
    monkeypatch.setattr(mock_vim.vim, 'command', Mock('vim.command'))
    return BlogIt.WordPressBlogPost.create_new_post(vim_vars)


def pytest_funcarg__post_header_line(request):
    return 'From: '


def pytest_funcarg__markdown(request):
    markdown_file = request.getfuncargvalue('markdown_file')
    pandoc_base_cmd = 'pandoc --from=markdown --to=html --no-wrap'
    pandoc_process = Popen(['pandoc', '--from=markdown', '--to=html',
                            '--no-wrap', markdown_file[0]],
                           stdout=PIPE, stderr=PIPE)
    pandoc_process.wait()
    if pandoc_process.returncode != 0:
        py.test.skip('pandoc returned with error')
    with open(markdown_file[0]) as f_mkd:
        return (f_mkd.read(), pandoc_process.stdout.read(), pandoc_base_cmd)

