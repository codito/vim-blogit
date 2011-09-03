#!/usr/bin/env python

import re
import sys
from locale import getpreferredencoding
from subprocess import Popen, PIPE
from blogit import blogclient, utils

try:
    import vim
except ImportError:
    # Used outside of vim (for testing)
    import doctest, minimock
    from minimock import Mock, mock
    from tests.mock_vim import vim
else:
    doctest = None

class AbstractPost(blogclient.AbstractBufferIO):
    BLOG_POST_ID = ''

    class BlogItServerVarUndefined(Exception):
        def __init__(self, label):
            super(AbstractPost.BlogItServerVarUndefined, self).__init__('Unknown: %s.' % label)
            self.label = label

    def __init__(self, post_data={}, meta_data_dict={}, headers=[],
                 post_body=''):
        """
        >>> AbstractPost(headers=['a', 'b', 'c']).meta_data_dict
        {'Body': '', 'a': 'a', 'c': 'c', 'b': 'b'}
        """
        self.post_data = post_data
        self.new_post_data = {}
        self.meta_data_dict = {'Body': post_body}
        for h in headers:
            self.meta_data_dict[h] = h
        self.meta_data_dict.update(meta_data_dict)
        self.meta_data_dict['Body'] = post_body
        self.HEADERS = headers
        self.POST_BODY = post_body   # for transition

    def __getattr__(self, name):
        """

        >>> p = AbstractPost()
        >>> mock('p.get_server_var_default', tracker=None)
        >>> mock('p.display_header_default', tracker=None)
        >>> p.get_server_var__foo() == p.get_server_var_default('foo')
        True
        >>> p.get_server_var__A() == p.get_server_var_default('A')
        True
        >>> p.display_header__A() == p.display_header_default('A')
        True
        >>> minimock.restore()
        """

        def base_name():
            start = name.find('__') + 2
            return name[start:]
        if name.startswith('get_server_var__'):
            return lambda: self.get_server_var_default(base_name())
        elif name.startswith('set_server_var__'):
            return lambda val: \
                    self.set_server_var_default(base_name(), val)
        elif name.startswith('display_header__'):
            return lambda: self.display_header_default(base_name())
        elif name.startswith('read_header__'):
            return lambda val: self.read_header_default(base_name(), val)
        raise AttributeError

    def read_header(self, line):
        """ Reads the meta-data line as used in a vim buffer.

        >>> mock('AbstractPost.read_header_default')
        >>> AbstractPost().read_header('tag: value')
        Called AbstractPost.read_header_default('tag', u'value')
        >>> minimock.restore()
        """
        r = re.compile('^(.*?): (.*)$')
        m = r.match(line)
        label, v = m.group(1, 2)
        getattr(self, 'read_header__' + label)(unicode(v.strip(), 'utf-8'))

    def read_body(self, lines):
        r"""
        >>> mock('AbstractPost.read_header_default')
        >>> AbstractPost().read_body(['one', 'two'])
        Called AbstractPost.read_header_default('Body', 'one\ntwo')
        >>> minimock.restore()
        """
        self.read_header__Body('\n'.join(lines).strip())

    def read_post(self, lines):
        r""" Returns the dict from given text of the post.

        >>> AbstractPost(post_body='content', headers=['Tag']
        ...                    ).read_post(['Tag:  Value  ', '',
        ...                                 'Some Text', 'in two lines.' ])
        {'content': 'Some Text\nin two lines.', 'Tag': u'Value'}
        """
        self.set_server_var__Body('')
        for i, line in enumerate(lines):
            if line.strip() == '':
                self.read_body(lines[i + 1:])
                break
            self.read_header(line)
        return self.new_post_data

    def display(self):
        for label in self.HEADERS:
            yield self.display_header(label)
        yield ''
        for line in self.display_body():
            yield line

    def display_header(self, label):
        """
        Returns a header line formated as it will be displayed to the user.

        >>> AbstractPost().display_header('A')
        'A: <A>'
        >>> AbstractPost(meta_data_dict={'A': 'a'}
        ...                    ).display_header('A')
        'A: <A>'
        >>> AbstractPost(post_data={'b': 'two'},
        ...     meta_data_dict={'A': 'a'}).display_header('A')
        'A: <A>'
        >>> AbstractPost(post_data={'a': 'one', 'b': 'two'},
        ...     meta_data_dict={'A': 'a'}).display_header('A')
        'A: one'

        >>> class B(AbstractPost):
        ...     def display_header__to_be_tested(self):
        ...         return 'text'
        >>> B().display_header('to_be_tested')
        'to_be_tested: text'

        >>> AbstractPost().display_header__foo()
        '<foo>'
        """
        text = getattr(self, 'display_header__' + label)()
        return '%s: %s' % (label, unicode(text).encode('utf-8'))

    def display_header_default(self, label):
        return getattr(self, 'get_server_var__' + label)()

    def read_header_default(self, label, text):
        getattr(self, 'set_server_var__' + label)(text.strip())

    def get_server_var_default(self, label):
        """

        >>> AbstractPost().get_server_var_default('foo')
        '<foo>'
        >>> AbstractPost().get_server_var_default('foo_AS_bar'
        ... )     #doctest: +ELLIPSIS
        Traceback (most recent call last):
            ...
        BlogItServerVarUndefined: Unknown: foo_AS_bar.
        """
        try:
            try:
                return self.post_data[self.meta_data_dict[label]]
            except KeyError:
                return self.post_data[label]
        except KeyError:
            if '_AS_' in label:
                raise self.BlogItServerVarUndefined(label)
            else:
                return self.get_server_var_not_found(label)

    def get_server_var_not_found(self, label):
        return '<%s>' % label

    def get_server_var_different_type(self, label, from_type):
        """
        >>> AbstractPost(post_data={'a': 'one, two, three' },
        ...     meta_data_dict={'Tags': 'a'}).display_header('Tags')
        'Tags: one, two, three'
        >>> AbstractPost({'a': [ 'one', 'two', 'three' ]},
        ...                     {'Tags_AS_list': 'a'}
        ...                    ).display_header('Tags')
        'Tags: one, two, three'
        >>> AbstractPost({}).display_header('Tags')
        'Tags: <Tags>'
        """
        try:
            val = getattr(self, 'get_server_var__%s_AS_%s' %
                                (label, from_type))()
        except self.BlogItServerVarUndefined:
            return self.get_server_var_default(label)
        else:
            return getattr(self, 'server_var_from__' + from_type)(val)

    def set_server_var_different_type(self, label, from_type, str_val):
        """
        >>> p = AbstractPost(post_data={'a': 'b'},
        ...     meta_data_dict={'Tags': 'a'})
        >>> p.set_server_var__Tags('one, two, three')
        >>> p.new_post_data
        {'a': 'one, two, three'}
        >>> p = AbstractPost({'a': [ 'b' ]},
        ...                         {'Tags_AS_list': 'a'})
        >>> p.set_server_var__Tags('one, two, three')
        >>> p.new_post_data
        {'a': ['one', 'two', 'three']}
        """
        val = getattr(self, 'server_var_to__' + from_type)(str_val)
        try:
            getattr(self, 'set_server_var__%s_AS_%s' % (label,
                                                        from_type))(val)
        except self.BlogItServerVarUndefined:
            self.set_server_var_default(label, str_val)

    def get_server_var__Date(self):
        return self.get_server_var_different_type('Date', 'DateTime')

    def set_server_var__Date(self, val):
        try:
            self.set_server_var_different_type('Date', 'DateTime', val)
        except ValueError:
            pass

    def get_server_var__Categories(self):
        return self.get_server_var_different_type('Categories', 'list')

    def set_server_var__Categories(self, val):
        self.set_server_var_different_type('Categories', 'list', val)

    def get_server_var__Tags(self):
        return self.get_server_var_different_type('Tags', 'list')

    def set_server_var__Tags(self, val):
        self.set_server_var_different_type('Tags', 'list', val)

    def server_var_to__DateTime(self, str_val):
        return utils.str_to_DateTime(str_val)

    def server_var_from__DateTime(self, val):
        return utils.DateTime_to_str(val)

    def server_var_to__list(self, str_val):
        return [s.strip() for s in str_val.split(',')]

    def server_var_from__list(self, val):
        return ', '.join(val)

    def set_server_var_default(self, label, val):
        try:
            self.new_post_data[self.meta_data_dict[label]] = val
        except KeyError:
            raise self.BlogItServerVarUndefined(label)


class BlogPost(AbstractPost):
    POST_TYPE = 'post'

    def __init__(self, blog_post_id, post_data={}, meta_data_dict={},
                 headers=None, post_body='description', vim_vars=None):
        if headers is None:
            headers = ['From', 'Id', 'Subject', 'Status',
                       'Categories', 'Tags', 'Date']
        if vim_vars is None:
            vim_vars = utils.VimVars()
        super(BlogPost, self).__init__(post_data, meta_data_dict, headers, post_body)
        self.vim_vars = vim_vars
        self.BLOG_POST_ID = blog_post_id

    def display_header__Status(self):
        d = self.get_server_var__Status_AS_dict()
        if d == '':
            return u'new'
        comment_typ_count = ['%s %s' % (d[key], text)
                for key, text in (('awaiting_moderation', 'awaiting'),
                                  ('spam', 'spam'))
                if d[key] > 0]
        if comment_typ_count == []:
            s = u''
        else:
            s = u' (%s)' % ', '.join(comment_typ_count)
        return (u'%(post_status)s \u2013 %(total_comments)s Comments'
                + s) % d

    def init_vim_buffer(self):
        super(BlogPost, self).init_vim_buffer()
        vim.command('nnoremap <buffer> gf :Blogit! list_comments<cr>')
        vim.command('setlocal ft=mail textwidth=0 ' +
                             'completefunc=BlogItComplete')
        vim.current.window.cursor = (8, 0)

    def read_header__Body(self, text):
        """
        >>> mock('BlogPost.format', returns='text', tracker=None)
        >>> p = BlogPost('')
        >>> p.read_header__Body('text'); p.new_post_data
        {'description': 'text'}
        >>> minimock.restore()
        """
        L = map(self.format, text.split('\n<!--more-->\n\n'))
        #super(BlogIt.BlogPost, self).read_header__Body(L[0])
        AbstractPost.read_header_default(self, 'Body', L[0])
        if len(L) == 2:
            self.read_header__Body_mt_more(L[1])

    def unformat(self, text):
        r"""
        >>> mock('vim.mocked_eval', returns_iter=[ '1', 'false' ])
        >>> mock('sys.stderr')
        >>> BlogPost(42).unformat('some random text')
        ...         #doctest: +NORMALIZE_WHITESPACE
        Called vim.mocked_eval("exists('blogit_unformat')")
        Called vim.mocked_eval('blogit_unformat')
        Called sys.stderr.write('Blogit: Error happend while filtering
                with:false\n')
        'some random text'

        >>> BlogPost(42).unformat('''\n\n \n
        ...         <!--blogit-- Post Source --blogit--> <h1>HTML</h1>''')
        'Post Source'

        >>> minimock.restore()
        """
        if text.lstrip().startswith('<!--blogit-- '):
            return (text.replace('<!--blogit--', '', 1).split(' --blogit-->', 1)[0].strip())
        try:
            return self.filter(text, 'unformat')
        except utils.FilterException, e:
            sys.stderr.write(e.message)
            return e.input_text

    def format(self, text):
        r"""

        Can raise FilterException.

        >>> mock('vim.mocked_eval')

        >>> BlogPost(42).format('one\ntwo\ntree\nfour')
        Called vim.mocked_eval("exists('blogit_format')")
        Called vim.mocked_eval("exists('blogit_postsource')")
        'one\ntwo\ntree\nfour'

        >>> mock('vim.mocked_eval', returns_iter=['1', 'sort', '0'])
        >>> BlogPost(42).format('one\ntwo\ntree\nfour')
        Called vim.mocked_eval("exists('blogit_format')")
        Called vim.mocked_eval('blogit_format')
        Called vim.mocked_eval("exists('blogit_postsource')")
        'four\none\ntree\ntwo\n'

        >>> mock('vim.mocked_eval', returns_iter=['1', 'false'])
        >>> BlogPost(42).format('one\ntwo\ntree\nfour')
        Traceback (most recent call last):
            ...
        FilterException

        >>> minimock.restore()
        """
        formated = self.filter(text, 'format')
        if self.vim_vars.blog_postsource:
            formated = "<!--blogit--\n%s\n--blogit-->\n%s" % (text,
                                                              formated)
        return formated

    def filter(self, text, vim_var='format'):
        r""" Filter text with command in vim_var.

        Can raise FilterException.

        >>> mock('vim.mocked_eval')
        >>> BlogPost(42).filter('some random text')
        Called vim.mocked_eval("exists('blogit_format')")
        'some random text'

        >>> mock('vim.mocked_eval', returns_iter=[ '1', 'false' ])
        >>> BlogPost(42).filter('some random text')
        Traceback (most recent call last):
            ...
        FilterException

        >>> mock('vim.mocked_eval', returns_iter=[ '1', 'rev' ])
        >>> BlogPost(42).filter('')
        Called vim.mocked_eval("exists('blogit_format')")
        Called vim.mocked_eval('blogit_format')
        ''

        >>> mock('vim.mocked_eval', returns_iter=[ '1', 'rev' ])
        >>> BlogPost(42).filter('some random text')
        Called vim.mocked_eval("exists('blogit_format')")
        Called vim.mocked_eval('blogit_format')
        'txet modnar emos\n'

        >>> mock('vim.mocked_eval', returns_iter=[ '1', 'rev' ])
        >>> BlogPost(42).filter(
        ...         'some random text\nwith a second line')
        Called vim.mocked_eval("exists('blogit_format')")
        Called vim.mocked_eval('blogit_format')
        'txet modnar emos\nenil dnoces a htiw\n'

        >>> minimock.restore()

        """
        filter = self.vim_vars.vim_variable(vim_var)
        if filter is None:
            return text
        try:
            p = Popen(filter, shell=True, stdin=PIPE, stdout=PIPE,
                      stderr=PIPE)
            try:
                p.stdin.write(text.encode(getpreferredencoding()))
            except UnicodeDecodeError:
                p.stdin.write(text.decode('utf-8')\
                                  .encode(getpreferredencoding()))
            p.stdin.close()
            if p.wait():
                raise utils.FilterException(p.stderr.read(), text, filter)
            return p.stdout.read().decode(getpreferredencoding())\
                                  .encode('utf-8')
        except utils.FilterException:
            raise
        except Exception, e:
            raise utils.FilterException(unicode(e), text, filter)

    def display_body(self):
        """
        Yields the lines of a post body.
        """
        content = self.unformat(self.post_data.get(self.POST_BODY, ''))
        for line in content.splitlines():
            yield line

        if self.post_data.get('mt_text_more'):
            yield ''
            yield '<!--more-->'
            yield ''
            content = self.unformat(self.post_data["mt_text_more"])
            for line in content.splitlines():
                yield line


class Page(BlogPost):
    POST_TYPE = 'page'

    def __init__(self, blog_post_id, post_data={}, meta_data_dict={},
                 headers=None, post_body='description', vim_vars=None,
                 client=None):
        if headers is None:
            headers = ['From', 'Id', 'Subject', 'Status', 'Categories',
                       'Date']
        super(Page, self).__init__(blog_post_id, post_data,
                                          meta_data_dict, headers,
                                          post_body, vim_vars)

    def read_header__Id(self, text):
        """
        >>> mock('BlogPost.set_server_var_default')
        >>> Page(42).read_header__Id('42 (about)')
        Called BlogPost.set_server_var_default('Page', 'about')
        Called BlogPost.set_server_var_default('Id', '42')
        >>> Page(42).read_header__Id(' (about)')
        Called BlogPost.set_server_var_default('Page', 'about')
        Called BlogPost.set_server_var_default('Id', '')
        >>> minimock.restore()
        """
        id, page = re.match('(\d*) *\((.*)\)', text).group(1, 2)
        self.set_server_var__Page(page)
        #super(BlogIt.Page, self).read_header__Id(id)
        BlogPost.read_header_default(self, 'Id', id)

    def display_header__Id(self):
        """
        >>> mock('BlogPost.get_server_var_default',
        ...      returns_iter=[42, 'about'], tracker=None)
        >>> Page(42).display_header__Id()
        '42 (about)'
        >>> minimock.restore()
        """
        #super(BlogIt.Page, self).display_header__Id()
        return '%s (%s)' % (BlogPost.display_header_default(self, 'Id'),
                            self.get_server_var__Page())

if doctest is not None:
    from blogit import core
    blogit = core.BlogIt()
