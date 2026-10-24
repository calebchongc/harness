"""Tests for scripts/check-issue-image.py: python3 scripts/check_issue_image_test.py"""

import importlib.util
import pathlib
import unittest

_spec = importlib.util.spec_from_file_location(
    "check_issue_image", pathlib.Path(__file__).with_name("check-issue-image.py")
)
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)


class ImageUrls(unittest.TestCase):
    def test_markdown_and_html_images_in_order_without_duplicates(self):
        body = (
            'See <img width="300" src="https://github.com/user-attachments/assets/b"> and\n'
            "![first](https://raw.githubusercontent.com/o/r/issue-media/1/a.png)\n"
            "![again](https://raw.githubusercontent.com/o/r/issue-media/1/a.png)"
        )
        self.assertEqual(
            check.image_urls(body),
            [
                "https://github.com/user-attachments/assets/b",
                "https://raw.githubusercontent.com/o/r/issue-media/1/a.png",
            ],
        )

    def test_links_and_code_are_not_images(self):
        body = "[a link](https://example.com/a.png) and `![x](y)` text"
        self.assertEqual(check.image_urls(body), ["y"])
        self.assertEqual(check.image_urls("[a link](https://example.com/a.png)"), [])

    def test_titled_markdown_image(self):
        self.assertEqual(
            check.image_urls('![shot](https://github.com/user-attachments/assets/c "the bug")'),
            ["https://github.com/user-attachments/assets/c"],
        )


class Hosts(unittest.TestCase):
    def test_only_https_github_hosts(self):
        self.assertTrue(check.github_hosted("https://github.com/user-attachments/assets/a"))
        self.assertTrue(check.github_hosted("https://raw.githubusercontent.com/o/r/b/x.png"))
        self.assertTrue(check.github_hosted("https://private-user-images.githubusercontent.com/1/x.png"))
        self.assertFalse(check.github_hosted("http://github.com/x.png"))
        self.assertFalse(check.github_hosted("https://github.com.evil.example/x.png"))
        self.assertFalse(check.github_hosted("https://example.com/github.com/x.png"))
        self.assertFalse(check.github_hosted("y"))


class Verdict(unittest.TestCase):
    def test_no_image_asks_for_one(self):
        labels, comment = check.verdict([], None)
        self.assertEqual(labels, {check.NEEDS_IMAGE})
        self.assertIn("no image", comment)

    def test_image_without_a_model_answer_clears_everything(self):
        self.assertEqual(check.verdict(["u"], None), (set(), None))

    def test_matching_image_with_nothing_private_is_quiet(self):
        self.assertEqual(check.verdict(["u"], {"shows_issue": 0.9, "private": 0.1}), (set(), None))

    def test_unrelated_image_is_labelled(self):
        labels, comment = check.verdict(["u"], {"shows_issue": 0.1, "private": 0.1})
        self.assertEqual(labels, {check.IMAGE_UNCLEAR})
        self.assertIn("doesn't seem to show", comment)

    def test_private_details_warn_without_a_label(self):
        labels, comment = check.verdict(["u"], {"shows_issue": 0.9, "private": 0.95})
        self.assertEqual(labels, set())
        self.assertIn("private details", comment)


class ModelText(unittest.TestCase):
    def test_images_are_replaced_and_the_body_is_capped(self):
        body = "before ![a](https://x/a.png) <img src='https://x/b.png'> after" + "z" * 5000
        text = check.without_images(body)
        self.assertTrue(text.startswith("before [image]"))
        self.assertNotIn("https://x/", text)
        self.assertEqual(len(text), check.BODY_CHARS)


if __name__ == "__main__":
    unittest.main()
