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
import socket
import SocketServer
import time

import py
try:
    import execnet
except ImportError:
    try:
        from py import execnet
    except ImportError:
        execnet = None


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
    if execnet is None:
        py.test.skip('Install execnet to run vim acceptance tests.')
    #skip_assert_port_available('localhost', 8888)
    vim_proc = Popen(['vim', '-c', 'pyfile socketserver.py'])
    # changing socketservers listen port fails:
    # '-c', 'python import sys; sys.argv = ["localhost:7777"]',
    gw = create_socket_gateway('localhost', 8888)
    def teardown():
        try:
            channel = gw.remote_exec('import vim; vim.command("q!")')
            for i in range(90):
                if not vim_proc.poll() is None:
                    break
                time.sleep(1)
            else:
                vim_proc.kill()    # only works in python2.6+
            gw.exit()
        except:
            pass
    request.addfinalizer(teardown)
    return gw


def skip_assert_port_available(host, port):
    """ Warning: Only works in python2.6+ """
    try:
        sock = SocketServer.TCPServer((host, port),
                                        SocketServer.BaseRequestHandler)
    except socket.error, e:
        if e.args[0] == 98:
            # 'Address already in use'
            py.test.skip('Port %s is already in use.' % port)
        else:
            py.test.skip('Failed to start socketserver: %s.' % str(e.args))
    finally:
        sock.shutdown()    # needs python2.6+


def create_socket_gateway(host, port):
    for i in range(90):
        try:
            return execnet.SocketGateway(host, port)
        except socket.error, e:
            if e.args[0] == 111:
                # 'Conection refused': Server isn't up, yet.
                time.sleep(1)
            else:
                raise Exception(e.args)    #py.test doesn't like socket.error
    else:
        py.test.skip('failed to connect to vim via socketserver.')
