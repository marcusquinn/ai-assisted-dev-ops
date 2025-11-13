#!/usr/bin/env python3
"""
LinkedIn Automation Script for AI DevOps Framework
Automates LinkedIn interactions like liking posts on timeline

Author: AI DevOps Framework
Version: 1.3.1

IMPORTANT: This script is for educational purposes and personal use only.
Always respect LinkedIn's Terms of Service and use responsibly.
"""

import time
import random
import os
import sys
from typing import List, Dict, Optional
import json
from datetime import datetime

try:
    from playwright.sync_api import sync_playwright, Page, Browser
    PLAYWRIGHT_AVAILABLE = True
except ImportError:
    PLAYWRIGHT_AVAILABLE = False

try:
    from selenium import webdriver
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.webdriver.chrome.options import Options
    SELENIUM_AVAILABLE = True
except ImportError:
    SELENIUM_AVAILABLE = False

class LinkedInAutomation:
    """LinkedIn automation class with ethical guidelines"""
    
    def __init__(self, headless: bool = False, delay_range: tuple = (2, 5)):
        self.headless = headless
        self.delay_range = delay_range
        self.session_stats = {
            'likes_given': 0,
            'posts_processed': 0,
            'errors': 0,
            'start_time': datetime.now()
        }
        
    def random_delay(self, min_delay: float = None, max_delay: float = None):
        """Add random delay to mimic human behavior"""
        if min_delay is None:
            min_delay = self.delay_range[0]
        if max_delay is None:
            max_delay = self.delay_range[1]
        
        delay = random.uniform(min_delay, max_delay)
        print(f"⏳ Waiting {delay:.1f} seconds...")
        time.sleep(delay)
    
    def playwright_automation(self, email: str, password: str, max_likes: int = 10):
        """LinkedIn automation using Playwright"""
        if not PLAYWRIGHT_AVAILABLE:
            print("❌ Playwright not available. Install with: pip install playwright")
            return False
            
        print("🎭 Starting LinkedIn automation with Playwright...")
        
        with sync_playwright() as p:
            # Launch browser
            browser = p.chromium.launch(headless=self.headless)
            context = browser.new_context(
                user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
            )
            page = context.new_page()
            
            try:
                # Login to LinkedIn
                if not self._playwright_login(page, email, password):
                    return False
                
                # Navigate to feed
                print("📰 Navigating to LinkedIn feed...")
                page.goto("https://www.linkedin.com/feed/")
                page.wait_for_load_state("networkidle")
                
                # Like posts on timeline
                self._playwright_like_posts(page, max_likes)
                
                # Print session summary
                self._print_session_summary()
                
                return True
                
            except Exception as e:
                print(f"❌ Error during automation: {e}")
                self.session_stats['errors'] += 1
                return False
            finally:
                browser.close()
    
    def _playwright_login(self, page: Page, email: str, password: str) -> bool:
        """Login to LinkedIn using Playwright"""
        try:
            print("🔐 Logging into LinkedIn...")
            page.goto("https://www.linkedin.com/login")
            
            # Fill login form
            page.fill('input[name="session_key"]', email)
            page.fill('input[name="session_password"]', password)
            
            # Click login button
            page.click('button[type="submit"]')
            
            # Wait for navigation
            page.wait_for_load_state("networkidle")
            
            # Check if login was successful
            if "feed" in page.url or "mynetwork" in page.url:
                print("✅ Successfully logged into LinkedIn")
                return True
            else:
                print("❌ Login failed - check credentials")
                return False
                
        except Exception as e:
            print(f"❌ Login error: {e}")
            return False
    
    def _playwright_like_posts(self, page: Page, max_likes: int):
        """Like posts on LinkedIn timeline using Playwright"""
        print(f"👍 Starting to like posts (max: {max_likes})...")
        
        likes_given = 0
        scroll_attempts = 0
        max_scrolls = 5
        
        while likes_given < max_likes and scroll_attempts < max_scrolls:
            # Find like buttons that haven't been clicked
            like_buttons = page.query_selector_all(
                'button[aria-label*="Like"][aria-pressed="false"]'
            )
            
            if not like_buttons:
                print("📜 Scrolling to load more posts...")
                page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
                self.random_delay(3, 6)
                scroll_attempts += 1
                continue
            
            # Like posts with random selection
            for button in like_buttons[:min(3, max_likes - likes_given)]:
                try:
                    # Scroll button into view
                    button.scroll_into_view_if_needed()
                    self.random_delay(1, 3)
                    
                    # Click like button
                    button.click()
                    likes_given += 1
                    self.session_stats['likes_given'] += 1
                    self.session_stats['posts_processed'] += 1
                    
                    print(f"👍 Liked post {likes_given}/{max_likes}")
                    
                    # Random delay between likes
                    self.random_delay()
                    
                    if likes_given >= max_likes:
                        break
                        
                except Exception as e:
                    print(f"⚠️ Error liking post: {e}")
                    self.session_stats['errors'] += 1
                    continue
            
            # Scroll for more content
            if likes_given < max_likes:
                page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
                self.random_delay(3, 6)
                scroll_attempts += 1
        
        print(f"✅ Completed liking session: {likes_given} posts liked")
    
    def _print_session_summary(self):
        """Print automation session summary"""
        duration = datetime.now() - self.session_stats['start_time']
        
        print("\n" + "="*50)
        print("📊 LinkedIn Automation Session Summary")
        print("="*50)
        print(f"👍 Posts liked: {self.session_stats['likes_given']}")
        print(f"📰 Posts processed: {self.session_stats['posts_processed']}")
        print(f"❌ Errors: {self.session_stats['errors']}")
        print(f"⏱️ Duration: {duration}")
        print(f"🕐 Started: {self.session_stats['start_time'].strftime('%Y-%m-%d %H:%M:%S')}")
        print("="*50)

def main():
    """Main function for LinkedIn automation"""
    print("🔗 LinkedIn Automation for AI DevOps Framework")
    print("⚠️  IMPORTANT: Use responsibly and respect LinkedIn's Terms of Service")
    print("")
    
    # Check if automation tools are available
    if not PLAYWRIGHT_AVAILABLE and not SELENIUM_AVAILABLE:
        print("❌ No browser automation tools available")
        print("Install with: pip install playwright selenium")
        print("Then run: playwright install")
        return
    
    # Get credentials from environment or prompt
    email = os.getenv('LINKEDIN_EMAIL')
    password = os.getenv('LINKEDIN_PASSWORD')
    
    if not email or not password:
        print("🔐 LinkedIn credentials not found in environment variables")
        print("Set LINKEDIN_EMAIL and LINKEDIN_PASSWORD environment variables")
        print("Or run with: LINKEDIN_EMAIL=your@email.com LINKEDIN_PASSWORD=yourpass python linkedin-automation.py")
        return
    
    # Configuration
    max_likes = int(os.getenv('LINKEDIN_MAX_LIKES', '10'))
    headless = os.getenv('LINKEDIN_HEADLESS', 'false').lower() == 'true'
    
    print(f"⚙️ Configuration:")
    print(f"   Email: {email}")
    print(f"   Max likes: {max_likes}")
    print(f"   Headless: {headless}")
    print("")
    
    # Create automation instance
    automation = LinkedInAutomation(headless=headless)
    
    # Run automation
    if PLAYWRIGHT_AVAILABLE:
        success = automation.playwright_automation(email, password, max_likes)
    else:
        print("❌ Playwright not available")
        success = False
    
    if success:
        print("🎉 LinkedIn automation completed successfully!")
    else:
        print("❌ LinkedIn automation failed")

if __name__ == "__main__":
    main()
