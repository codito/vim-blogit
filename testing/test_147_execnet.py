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


from __future__ import with_statement

from subprocess import Popen

import py

def test_with_execnet(vim_gateway):
    channel = vim_gateway.remote_exec("""
        channel.send(3)
        """)
    buf = channel.receive()
    channel.close()
    assert buf == 3


def test_sending(vim_gateway):
    channel = vim_gateway.remote_exec("""
        import vim
        vim.current.buffer[:] = ['hallo']
        vim.command('%s/a/e')
        channel.send(vim.current.buffer[0])
        """)
    buf = channel.receive()
    channel.close()
    assert buf == 'hello'


def test_blogit_preview(vim_gateway):
    # XXX: delete .t.mkd.swp
    channel = vim_gateway.remote_exec("""
        import vim
        vim.command('e t.mkd')
        vim.command('Blogit this')
        vim.command('py p = blogit.current_post')
        vim.command('py vim.current.buffer[:] = ' +
                    'p.read_post(vim.current.buffer[:])[p.POST_BODY]' +
                    '.splitlines()')
        channel.send(vim.current.buffer[:])
        """)
    buf = channel.receive()
    channel.close()
    with open('t.html') as f:
        text = f.read()
    assert ''.join(buf).replace(' ', '') == \
            ''.join(text.splitlines()).replace(' ', '')


def test_blogit_format_setting(vim_gateway):
    channel = vim_gateway.remote_exec("""
        import vim
        channel.send(vim.eval('blogit_format'))
        """)
    buf = channel.receive()
    channel.close()
    assert buf == 'pandoc --from=markdown --to=html'


def ____test_execnet_buffer_pickle(vim_gateway):
    import pickle
    channel = vim_gateway.remote_exec(r"""
        import vim
        vim.command('py import pickle')
        vim.command('py import vim')
        vim.command('py b = pickle.dumps([1, 2, 3])')
        vim.command('py if b == "": b = "empty"')
        vim.command('py vim.current.buffer[0] = b.split("\n")[0]')
        vim.command('py if vim.current.buffer[0] == "": vim.current.buffer[0] = "broken"')
        channel.send(vim.current.buffer[0])""")
    buf = channel.receive()
    channel.close()
    assert buf != 'broken'    # fails
    #assert '\n'.join(buf) == pickle.dumps([1, 2, 3])    # '(lp0\nI1\naI2\naI3\na.'


def test_execnet_eval_pickle(vim_gateway):
    import pickle
    channel = vim_gateway.remote_exec(r"""
        import vim
        vim.command('py import pickle')
        vim.command('py import vim')
        vim.command('py b = pickle.dumps([1, 2, 3])')
        vim.command('''py vim.command("let execnet='%s'" % b)''')
        b = vim.eval("execnet")
        channel.send(b)""")
    buf = channel.receive()
    channel.close()
    assert buf == pickle.dumps([1, 2, 3])


def pytest_funcarg__vim_gateway(request):
    if not request.config.option.acceptance:
        py.test.skip('specify -A to run acceptance tests')
    try:
        import execnet
    except ImportError:
        try:
            from py import execnet
        except ImportError:
            py.test.skip('Install execnet to run vim acceptance tests.')
        vim_proc = Popen(['vim', '-c',
                          'python import sys; sys.argv = ["localhost:8888"]',
                          '-c', 'pyfile socketserver.py'])
    while True:
        try:
            gw = execnet.SocketGateway('localhost', 8888)
            break
        except:
            pass
    def teardown():
        try:
            channel = gw.remote_exec('import vim; vim.command("q!")')
            while vim_proc.poll() is None:
                pass
            gw.exit()
        except:
            pass
    request.addfinalizer(teardown)
    return gw


