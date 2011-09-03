#!/usr/bin/env python
import sys
import xmlrpclib
from blogit import blogpost, utils

try:
    import vim
except ImportError:
    # Used outside of vim (for testing)
    import doctest, minimock
    from minimock import Mock, mock
    from tests.mock_vim import vim
else:
    doctest = None

class Comment(blogpost.AbstractPost):

    def __init__(self, post_data={}, meta_data_dict={}, headers=None,
                 post_body='content'):
        if headers is None:
            headers = ['Status', 'Author', 'ID', 'Parent', 'Date', 'Type']
        super(Comment, self).__init__(post_data, meta_data_dict,
                 headers, post_body)

    def display_body(self):
        """
        Yields the lines of a post body.
        """
        content = self.post_data.get(self.POST_BODY, '')
        for line in content.split('\n'):
            # not splitlines to preserve \r\n in comments.
            yield line

    @classmethod
    def create_emtpy_comment(cls, *a, **d):
        c = cls(*a, **d)
        c.read_post(['Status: new', 'Author: ', 'ID: ', 'Parent: 0',
                     'Date: ', 'Type: ', '', ''])
        c.post_data = c.new_post_data
        return c


class CommentList(Comment):
    POST_TYPE = 'comments'

    def __init__(self, meta_data_dict={}, headers=None,
                 post_body='content', comment_categories=None):
        super(CommentList, self).__init__({}, meta_data_dict,
                 headers, post_body)
        if comment_categories is None:
            comment_categories = ('New', 'In Moderadation', 'Spam',
                                  'Published')
        self.comment_categories = comment_categories
        self.empty_comment_list()

    def init_vim_buffer(self):
        super(CommentList, self).init_vim_buffer()
        vim.command('setlocal linebreak completefunc=BlogItComplete ' +
                           'foldmethod=marker ' +
                           'foldtext=BlogItCommentsFoldText()')

    def empty_comment_list(self):
        self.comment_list = {}
        self.comments_by_category = {}
        empty_comment = Comment.create_emtpy_comment({}, self.meta_data_dict, self.HEADERS,
                                                     self.POST_BODY)
        self.add_comment('New', empty_comment.post_data)

    def add_comment(self, category, comment_dict):
        """ Callee must garanty that no comment with same id is in list.

        >>> cl = CommentList()
        >>> cl.add_comment('hold', {'ID': '1',
        ...                         'content': 'Some Text',
        ...                         'Status': 'hold'})
        >>> [ (id, c.post_data) for id, c in cl.comment_list.iteritems()
        ... ]    #doctest: +NORMALIZE_WHITESPACE +ELLIPSIS
        [(u'', {'Status': u'new', 'Parent': u'0', 'Author': u'',
          'content': '', 'Date': u'', 'Type': u'', 'ID': u''}),
         ('1', {'content': 'Some Text', 'Status': 'hold', 'ID': '1'})]
        >>> [ (cat, [ c.post_data['ID'] for c in L ])
        ...         for cat, L in cl.comments_by_category.iteritems()
        ... ]    #doctest: +NORMALIZE_WHITESPACE
        [('New', [u'']), ('hold', ['1'])]
        >>> cl.add_comment('spam', {'ID': '1'}
        ...               )    #doctest: +ELLIPSIS
        Traceback (most recent call last):
            ...
        AssertionError...
        """
        comment = Comment(comment_dict, self.meta_data_dict,
                                 self.HEADERS, self.POST_BODY)
        assert not comment.get_server_var__ID() in self.comment_list
        self.comment_list[comment.get_server_var__ID()] = comment
        try:
            self.comments_by_category[category].append(comment)
        except KeyError:
            self.comments_by_category[category] = [comment]

    def display(self):
        """

        >>> list(CommentList().display())
        ...     #doctest: +NORMALIZE_WHITESPACE
        ['======================================================================== {{{1',
         '     New',
         '======================================================================== {{{2',
         'Status: new',
         'Author: ',
         'ID: ',
         'Parent: 0',
         'Date: ',
         'Type: ',
         '',
         '',
         '']
        """
        for heading in self.comment_categories:
            try:
                comments = self.comments_by_category[heading]
            except KeyError:
                continue

            yield 72 * '=' + ' {{{1'
            yield 5 * ' ' + heading.capitalize()

            fold_levels = {}
            for comment in reversed(comments):
                try:
                    fold = fold_levels[comment.post_data['parent']] + 2
                except KeyError:
                    fold = 2
                fold_levels[comment.get_server_var__ID()] = fold
                yield 72 * '=' + ' {{{%s' % fold
                for line in comment.display():
                    yield line
                yield ''

    def _read_post__read_comment(self, lines):
        self.new_post_data = {}
        new_post_data = super(CommentList, self).read_post(lines)
        return Comment(new_post_data, self.meta_data_dict, self.HEADERS, self.POST_BODY)

    def read_post(self, lines):
        r""" Yields a dict for each comment in the current buffer.

        >>> cl = CommentList().read_post([
        ...     60 * '=', 'ID: 1 ', 'Status: hold', '', 'Text',
        ...     60 * '=', 'ID:  ', 'Status: hold', '', 'Text',
        ...     60 * '=', 'ID: 3', 'Status: spam', '', 'Text' ])
        >>> [ c.post_data for c in cl ]     #doctest: +NORMALIZE_WHITESPACE
        [{'content': 'Text', 'Status': u'hold', 'ID': u'1'},
         {'content': 'Text', 'Status': u'hold', 'ID': u''},
         {'content': 'Text', 'Status': u'spam', 'ID': u'3'}]

        >>> mock('Comment.create_emtpy_comment',
        ...      returns=Comment(headers=['Tag', 'Tag2']))
        >>> cl = CommentList(headers=['Tag', 'Tag2']).read_post([
        ...     60 * '=', 'Tag2: Val2 ', '',
        ...     60 * '=',
        ...     'Tag:  Value  ', '', 'Some Text', 'in two lines.   ' ])
        Called Comment.create_emtpy_comment(
            {},
            {'Body': 'content', 'Tag': 'Tag', 'Tag2': 'Tag2'},
            ['Tag', 'Tag2'],
            'content')
        >>> [ c.post_data for c in cl ]     #doctest: +NORMALIZE_WHITESPACE
        [{'content': '', 'Tag2': u'Val2'},
         {'content': 'Some Text\nin two lines.', 'Tag': u'Value'}]
        >>> minimock.restore()
        """
        j = 0
        lines = list(lines)
        for i, line in enumerate(lines):
            if line.startswith(60 * '='):
                if i - j > 1:
                    yield self._read_post__read_comment(lines[j:i])
                j = i + 1
        yield self._read_post__read_comment(lines[j:])

    def changed_comments(self, lines):
        """ Yields comments with changes made to in the vim buffer.

        >>> cl = CommentList()
        >>> for comment_dict in [
        ...         {'ID': '1', 'content': 'Old Text',
        ...          'Status': 'hold', 'unknown': 'tag'},
        ...         {'ID': '2', 'content': 'Same Text',
        ...          'Date': 'old', 'Status': 'hold'},
        ...         {'ID': '3', 'content': 'Same Again',
        ...          'Status': 'hold'}]:
        ...     cl.add_comment('', comment_dict)
        >>> [ c.post_data for c in cl.changed_comments([
        ...     60 * '=', 'ID: 1 ', 'Status: hold', '', 'Changed Text',
        ...     60 * '=', 'ID:  ', 'Status: hold', '', 'New Text',
        ...     60 * '=', 'ID: 2', 'Status: hold', 'Date: new', '',
        ...             'Same Text',
        ...     60 * '=', 'ID: 3', 'Status: spam', '', 'Same Again' ])
        ... ]      #doctest: +NORMALIZE_WHITESPACE +ELLIPSIS
        [{'content': 'Changed Text', 'Status': u'hold', 'unknown': 'tag',
          'ID': u'1'},
         {'Status': u'hold', 'content': 'New Text', 'Parent': u'0',
          'Author': u'', 'Date': u'', 'Type': u'', 'ID': u''},
         {'content': 'Same Again', 'Status': u'spam', 'ID': u'3'}]

        """

        for comment in self.read_post(lines):
            original_comment = self.comment_list[
                    comment.get_server_var__ID()].post_data
            new_comment = original_comment.copy()
            new_comment.update(comment.post_data)
            if original_comment != new_comment:
                comment.post_data = new_comment
                yield comment

    @classmethod
    def create_from_post(cls, blog_post):
        return cls(blog_post.BLOG_POST_ID, vim_vars=blog_post.vim_vars)


class WordPressCommentList(CommentList):

    def __init__(self, blog_post_id, meta_data_dict=None, headers=None,
                 post_body='content', vim_vars=None, client=None,
                 comment_categories=None):
        if meta_data_dict is None:
            meta_data_dict = {'Status': 'status', 'Author': 'author',
                              'ID': 'comment_id', 'Parent': 'parent',
                              'Date_AS_DateTime': 'date_created_gmt',
                              'Type': 'type', 'content': 'content',
                             }
        super(WordPressCommentList, self).__init__(
                meta_data_dict, headers, post_body, comment_categories)
        if vim_vars is None:
            vim_vars = utils.VimVars()
        self.vim_vars = vim_vars
        if client is None:
            client = xmlrpclib.ServerProxy(self.vim_vars.blog_url)
        self.client = client
        self.BLOG_POST_ID = blog_post_id

    def send(self, lines):
        """ Send changed and new comments to server.

        >>> c = WordPressCommentList(42)
        >>> mock('sys.stderr')
        >>> mock('c.getComments')
        >>> mock('c.changed_comments',
        ...         returns=[ Comment(post_data, c.meta_data_dict)
        ...             for post_data in
        ...                 { 'status': 'new', 'content': 'New Text' },
        ...                 { 'status': 'will fail', 'comment_id': 13 },
        ...                 { 'status': 'will succeed', 'comment_id': 7 },
        ...                 { 'status': 'rm', 'comment_id': 100 } ])
        >>> mock('xmlrpclib.MultiCall', returns=Mock(
        ...         'multicall', returns=[ 200, False, True, True ]))
        >>> c.send(None)    #doctest: +NORMALIZE_WHITESPACE
        Called xmlrpclib.MultiCall(<ServerProxy for example.com/RPC2>)
        Called c.changed_comments(None)
        Called multicall.wp.newComment( '', 'user', 'password', 42,
            {'status': 'approve', 'content': 'New Text'})
        Called multicall.wp.editComment( '', 'user', 'password', 13,
            {'status': 'will fail', 'comment_id': 13})
        Called multicall.wp.editComment( '', 'user', 'password', 7,
             {'status': 'will succeed', 'comment_id': 7})
        Called multicall.wp.deleteComment('', 'user', 'password', 100)
        Called multicall()
        Called sys.stderr.write('Server refuses update to 13.')
        Called c.getComments()

        >>> vim.current.buffer.change_buffer()
        >>> minimock.restore()

        """
        multicall = xmlrpclib.MultiCall(self.client)
        username, password = (self.vim_vars.blog_username,
                              self.vim_vars.blog_password)
        multicall_log = []
        for comment in self.changed_comments(lines):
            if comment.get_server_var__Status() == 'new':
                comment.set_server_var__Status('approve')
                comment.post_data.update(comment.new_post_data)
                multicall.wp.newComment('', username, password,
                                        self.BLOG_POST_ID,
                                        comment.post_data)
                multicall_log.append('new')
            elif comment.get_server_var__Status() == 'rm':
                multicall.wp.deleteComment('', username, password,
                                           comment.get_server_var__ID())
            else:
                comment_id = comment.get_server_var__ID()
                multicall.wp.editComment('', username, password,
                                         comment_id, comment.post_data)
                multicall_log.append(comment_id)
        for accepted, comment_id in zip(multicall(), multicall_log):
            if comment_id != 'new' and not accepted:
                sys.stderr.write('Server refuses update to %s.' %
                                 comment_id)
        return self.getComments()

    def _no_send(self, lines=[], push=None):
        """ Replace send() with this to prevent the user from commiting.
        """
        raise utils.NoPostException

    def getComments(self, offset=0):
        """ Lists the comments to a post with given id in a new buffer.

        >>> mock('xmlrpclib.MultiCall', returns=Mock(
        ...         'multicall', returns=[], tracker=None))
        >>> c = WordPressCommentList(42)
        >>> mock('c.display', returns=[])
        >>> mock('c.changed_comments', returns=[])
        >>> c.getComments()   #doctest: +NORMALIZE_WHITESPACE
        Called xmlrpclib.MultiCall(<ServerProxy for example.com/RPC2>)
        Called c.display()
        Called c.changed_comments([])

        >>> minimock.restore()
        """
        multicall = xmlrpclib.MultiCall(self.client)
        for comment_typ in ('hold', 'spam', 'approve'):
            multicall.wp.getComments('', self.vim_vars.blog_username,
                    self.vim_vars.blog_password,
                    {'post_id': self.BLOG_POST_ID, 'status': comment_typ,
                     'offset': offset, 'number': 1000})
        self.empty_comment_list()
        for comments, heading in zip(multicall(),
                ('In Moderadation', 'Spam', 'Published')):
            for comment_dict in comments:
                self.add_comment(heading, comment_dict)
        if list(self.changed_comments(self.display())) != []:
            msg = 'Bug in BlogIt: Deactivating comment editing:\n'
            for d in self.changed_comments(self.display()):
                msg += "  '%s'" % d['comment_id']
                msg += str(list(self.changed_comments(self.display())))
            self.send = self._no_send
            raise utils.BlogItBug(msg)
