import unittest
import blogit

class BlogitTestcase(unittest.TestCase):
    def setUp(self):
        from blogit import core
        self.blogit = core.BlogIt()

class BasicTestcase(BlogitTestcase):
    def runTest(self):
        assert self.blogit is not None, "Failed to create BlogIt object!"
        
        # Scenario: import/instantiate core interface in blogclient
        x = blogit.blogpost.BlogPost()
        assert x is not None

        # Scenario: import/instantiate clients
        from blogit.clients import wordpress

class WPTestcase(BlogitTestcase):
    def runTest(self):
        pass
