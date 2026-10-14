#!/usr/bin/env python3
"""Finite vendor XML fixtures for the browser Openbox layout derivation."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest import mock
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "guest/browser-runtime/openbox-config.py"
with mock.patch.object(sys, "dont_write_bytecode", True):
    SPEC = importlib.util.spec_from_file_location("browser_openbox_config_tests", SOURCE)
    OPENBOX = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(OPENBOX)

NAMESPACE = "http://openbox.org/3.4/rc"
TAG = "{" + NAMESPACE + "}"
DESKTOP_WHEELS = (
    '<mousebind button="Up" action="Click"><action name="GoToDesktop"><to>previous</to><wrap>yes</wrap></action></mousebind>',
    '<mousebind button="Down" action="Click"><action name="GoToDesktop"><to>next</to><wrap>yes</wrap></action></mousebind>',
    '<mousebind button="A-Up" action="Click"><action name="GoToDesktop"><to>previous</to></action></mousebind>',
    '<mousebind button="A-Down" action="Click"><action name="GoToDesktop"><to>next</to></action></mousebind>',
    '<mousebind button="C-A-Up" action="Click"><action name="GoToDesktop"><to>previous</to><wrap>no</wrap></action></mousebind>',
    '<mousebind button="C-A-Down" action="Click"><action name="GoToDesktop"><to>next</to><wrap>no</wrap></action></mousebind>',
)
TITLEBAR_WHEELS = (
    '<mousebind button="Up" action="Click"><action name="If"><query target="default"><shaded>no</shaded></query><then><action name="Shade"/></then><else><action name="Unshade"/><action name="Raise"/></else></action></mousebind>',
    '<mousebind button="Down" action="Click"><action name="If"><query target="default"><shaded>yes</shaded></query><then><action name="Unshade"/><action name="Focus"/></then><else><action name="Shade"/></else></action></mousebind>',
)
FIREFOX_RULE = '<application class="firefox" type="normal"><desktop>1</desktop><maximized>yes</maximized></application>'

VENDOR_XML = ('''<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <!-- Vendor desktop settings remain recognizable. -->
  <desktops><number>4</number><firstdesk>2</firstdesk><names><name>Main</name><name>Work</name></names><popupTime>875</popupTime></desktops>
  <keyboard>
    <!-- Keyboard desktop navigation is intentionally retained. -->
    <chainQuitKey>C-g</chainQuitKey>
    <keybind key="C-A-Left"><action name="GoToDesktop"><to>left</to><wrap>no</wrap></action></keybind>
    <keybind key="C-A-Right"><action name="GoToDesktop"><to>right</to><wrap>no</wrap></action></keybind>
    <keybind key="W-d"><action name="ToggleShowDesktop"/></keybind>
  </keyboard>
  <mouse>
    <dragThreshold>8</dragThreshold><doubleClickTime>200</doubleClickTime>
    <context name="Desktop">
      <!-- Only the six Desktop wheel bindings are removed. -->
      ''' + "\n      ".join(DESKTOP_WHEELS) + '''
      <mousebind button="Right" action="Press"><action name="ShowMenu"><menu>root-menu</menu></action></mousebind>
      <mousebind button="Middle" action="Press"><action name="ShowMenu"><menu>client-list-combined-menu</menu></action></mousebind>
    </context>
    <context name="Titlebar">
      <!-- Remove entire wheel bindings including conditional shade actions. -->
      ''' + "\n      ".join(TITLEBAR_WHEELS) + '''
      <mousebind button="Left" action="Press"><action name="Focus"/><action name="Raise"/></mousebind>
      <mousebind button="Left" action="DoubleClick"><action name="ToggleMaximize"/></mousebind>
      <mousebind button="Right" action="Press"><action name="ShowMenu"><menu>client-menu</menu></action></mousebind>
    </context>
    <context name="Frame">
      <mousebind button="A-Left" action="Drag"><action name="Move"/></mousebind>
      <mousebind button="A-Right" action="Drag"><action name="Resize"/></mousebind>
      <mousebind button="Up" action="Click"><action name="Raise"/></mousebind>
      <mousebind button="Down" action="Click"><action name="Lower"/></mousebind>
    </context>
    <context name="MoveResize">
      <mousebind button="Up" action="Click"><action name="Resize"><edge>top</edge></action></mousebind>
      <mousebind button="Down" action="Click"><action name="Move"/></mousebind>
    </context>
  </mouse>
  <resize><drawContents>yes</drawContents><popupShow>Nonpixel</popupShow></resize>
  <menu><file>menu.xml</file><hideDelay>200</hideDelay></menu>
  <applications>
    <!-- Existing application matching and order are preserved. -->
    <application class="XTerm" name="xterm"><desktop>3</desktop><maximized>no</maximized><position force="no"><x>10</x><y>20</y></position></application>
    <application type="dialog"><decor>yes</decor><focus>yes</focus></application>
  </applications>
</openbox_config>
''').encode("utf-8")


def parse(content):
    return ET.fromstring(content, parser=ET.XMLParser(target=ET.TreeBuilder(insert_comments=True)))


def semantics(element):
    """Compare XML meaning while ignoring indentation and namespace prefix spelling."""
    tag = "#comment" if element.tag is ET.Comment else element.tag
    return (tag, tuple(sorted(element.attrib.items())), (element.text or "").strip(),
            tuple(semantics(child) for child in element))


def expected_xml():
    # The expected diff is described with the fixture's complete literal binds,
    # independent of the production traversal and button-matching algorithm.
    content = VENDOR_XML
    for binding in DESKTOP_WHEELS + TITLEBAR_WHEELS:
        content = content.replace(binding.encode(), b"", 1)
    content = content.replace(b"<number>4</number>", b"<number>1</number>", 1)
    content = content.replace(b"<firstdesk>2</firstdesk>", b"<firstdesk>1</firstdesk>", 1)
    return content.replace(b"</applications>", FIREFOX_RULE.encode() + b"</applications>", 1)


class OpenboxConfigBoundaries(unittest.TestCase):
    def setUp(self):
        self.before = parse(VENDOR_XML)

    def invoke(self, root):
        return OPENBOX.build_config(ET.tostring(root, encoding="utf-8"))

    def test_exact_semantic_diff_is_eight_whole_bindings_two_desktop_values_and_one_rule(self):
        result = OPENBOX.build_config(VENDOR_XML)
        self.assertIs(type(result), bytes)
        after = parse(result)
        self.assertEqual(semantics(after), semantics(parse(expected_xml())))
        desktop = after.find(TAG + "mouse/" + TAG + "context[@name='Desktop']")
        titlebar = after.find(TAG + "mouse/" + TAG + "context[@name='Titlebar']")
        self.assertEqual([node.get("button") for node in desktop.findall(TAG + "mousebind")], ["Right", "Middle"])
        self.assertEqual([node.get("button") for node in titlebar.findall(TAG + "mousebind")], ["Left", "Left", "Right"])
        self.assertEqual(len(titlebar.findall(".//" + TAG + "action[@name='If']")), 0)
        applications = after.find(TAG + "applications")
        self.assertEqual(len(applications.findall(TAG + "application[@class='firefox']")), 1)
        self.assertEqual(semantics(applications[-1]), semantics(parse(
            ('<application xmlns="' + NAMESPACE + '" class="firefox" type="normal"><desktop>1</desktop><maximized>yes</maximized></application>').encode())))

    def test_keyboard_menus_frame_move_resize_and_existing_app_rules_are_preserved(self):
        after = parse(OPENBOX.build_config(VENDOR_XML))
        for section in ("keyboard", "resize", "menu"):
            with self.subTest(section=section):
                self.assertEqual(semantics(self.before.find(TAG + section)), semantics(after.find(TAG + section)))
        for context in ("Frame", "MoveResize"):
            with self.subTest(context=context):
                path = TAG + "mouse/" + TAG + "context[@name='" + context + "']"
                self.assertEqual(semantics(self.before.find(path)), semantics(after.find(path)))
        for context in ("Desktop", "Titlebar"):
            path = TAG + "mouse/" + TAG + "context[@name='" + context + "']/" + TAG + "mousebind[@button='Right']"
            self.assertEqual(semantics(self.before.find(path)), semantics(after.find(path)))
        old = self.before.find(TAG + "applications")
        new = after.find(TAG + "applications")
        self.assertEqual([semantics(node) for node in old], [semantics(node) for node in list(new)[:-1]])

    def test_namespace_and_comments_are_preserved(self):
        result = OPENBOX.build_config(VENDOR_XML)
        after = parse(result)
        self.assertIn(('xmlns="' + NAMESPACE + '"').encode(), result)
        self.assertNotIn(b"ns0:", result)
        self.assertEqual([node.text for node in self.before.iter() if node.tag is ET.Comment],
                         [node.text for node in after.iter() if node.tag is ET.Comment])
        self.assertTrue(all(node.tag.startswith(TAG) for node in after.iter() if node.tag is not ET.Comment))

    def test_missing_required_sections_fail_explicitly(self):
        for section in ("desktops", "mouse", "applications"):
            with self.subTest(section=section):
                root = parse(VENDOR_XML)
                root.remove(root.find(TAG + section))
                with self.assertRaisesRegex(ValueError, "^openbox_vendor_sections_missing$"):
                    self.invoke(root)

    def test_missing_desktop_number_or_firstdesk_fails_explicitly(self):
        for name in ("number", "firstdesk"):
            with self.subTest(name=name):
                root = parse(VENDOR_XML)
                desktops = root.find(TAG + "desktops")
                desktops.remove(desktops.find(TAG + name))
                with self.assertRaisesRegex(ValueError, "^openbox_vendor_desktops_missing$"):
                    self.invoke(root)

    def test_each_missing_wheel_binding_fails_instead_of_silently_accepting_vendor_drift(self):
        self.assertEqual(len(DESKTOP_WHEELS + TITLEBAR_WHEELS), 8)
        for binding in DESKTOP_WHEELS + TITLEBAR_WHEELS:
            with self.subTest(binding=binding):
                content = VENDOR_XML.replace(binding.encode(), b"", 1)
                with self.assertRaisesRegex(ValueError, "^openbox_vendor_wheel_bindings_unexpected$"):
                    OPENBOX.build_config(content)

    def test_extra_matching_wheel_binding_fails_explicitly(self):
        for context, binding in (("Desktop", DESKTOP_WHEELS[0]), ("Titlebar", TITLEBAR_WHEELS[1])):
            with self.subTest(context=context):
                root = parse(VENDOR_XML)
                target = root.find(TAG + "mouse/" + TAG + "context[@name='" + context + "']")
                target.append(parse(binding.encode().replace(b"<mousebind", ('<mousebind xmlns="' + NAMESPACE + '"').encode(), 1)))
                with self.assertRaisesRegex(ValueError, "^openbox_vendor_wheel_bindings_unexpected$"):
                    self.invoke(root)

    def test_wrong_or_missing_vendor_namespace_fails_explicitly(self):
        for content in (VENDOR_XML.replace(NAMESPACE.encode(), b"urn:wrong-openbox"),
                        VENDOR_XML.replace((' xmlns="' + NAMESPACE + '"').encode(), b"")):
            with self.subTest(content=content[:80]):
                with self.assertRaisesRegex(ValueError, "^openbox_vendor_namespace_invalid$"):
                    OPENBOX.build_config(content)

    def test_malformed_xml_fails(self):
        for content in (b"", b"<openbox_config>", VENDOR_XML.replace(b"</applications>", b"</different>")):
            with self.subTest(content=content[:80]):
                with self.assertRaises(ET.ParseError):
                    OPENBOX.build_config(content)


if __name__ == "__main__":
    unittest.main(verbosity=2)
