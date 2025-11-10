# 🎭 Playwright MCP Usage Examples

## 🚀 **Cross-Browser Testing**

### **Multi-Browser Test Suite**

```javascript
// Test across different browsers
const browsers = ['chromium', 'firefox', 'webkit'];

for (const browserName of browsers) {
  await playwright.runTest({
    browser: browserName,
    url: "https://your-website.com",
    test: "login-flow"
  });
}
```

### **Browser-Specific Feature Testing**

```javascript
// Test browser-specific features
await playwright.testBrowserFeatures({
  url: "https://your-website.com",
  features: ["webgl", "webrtc", "geolocation", "notifications"],
  browsers: ["chromium", "firefox", "webkit"]
});
```

## 🔄 **Automated User Flows**

### **E-commerce Checkout Flow**

```javascript
// Automate complete checkout process
await playwright.automateFlow({
  url: "https://your-ecommerce.com",
  steps: [
    { action: "click", selector: ".product-card:first-child" },
    { action: "click", selector: ".add-to-cart" },
    { action: "click", selector: ".cart-icon" },
    { action: "fill", selector: "#email", value: "test@example.com" },
    { action: "fill", selector: "#password", value: "testpass123" },
    { action: "click", selector: ".checkout-button" }
  ]
});
```

### **Form Validation Testing**

```javascript
// Test form validation scenarios
await playwright.testFormValidation({
  url: "https://your-website.com/contact",
  form: "#contact-form",
  scenarios: [
    { field: "email", value: "invalid-email", expectError: true },
    { field: "phone", value: "123", expectError: true },
    { field: "message", value: "", expectError: true }
  ]
});
```

## 📱 **Mobile & Responsive Testing**

### **Device-Specific Testing**

```javascript
// Test on various mobile devices
const devices = [
  'iPhone 12',
  'iPhone 12 Pro Max',
  'Samsung Galaxy S21',
  'iPad Pro'
];

for (const device of devices) {
  await playwright.testOnDevice({
    device: device,
    url: "https://your-website.com",
    tests: ["navigation", "forms", "media-queries"]
  });
}
```

### **Orientation Testing**

```javascript
// Test portrait and landscape orientations
await playwright.testOrientations({
  url: "https://your-website.com",
  device: "iPhone 12",
  orientations: ["portrait", "landscape"],
  captureScreenshots: true
});
```

## 🎯 **Performance Testing**

### **Load Time Analysis**

```javascript
// Measure page load performance
await playwright.measurePerformance({
  url: "https://your-website.com",
  metrics: [
    "domContentLoaded",
    "load",
    "firstContentfulPaint",
    "largestContentfulPaint"
  ],
  iterations: 5
});
```

### **Network Throttling Tests**

```javascript
// Test under different network conditions
const networkConditions = [
  { name: "Fast 3G", downloadThroughput: 1.5 * 1024 * 1024 / 8 },
  { name: "Slow 3G", downloadThroughput: 500 * 1024 / 8 },
  { name: "Offline", offline: true }
];

for (const condition of networkConditions) {
  await playwright.testWithNetwork({
    url: "https://your-website.com",
    networkCondition: condition,
    timeout: 30000
  });
}
```

## 🔍 **Visual Testing & Screenshots**

### **Visual Regression Suite**

```javascript
// Comprehensive visual regression testing
await playwright.visualRegressionSuite({
  baseUrl: "https://your-website.com",
  pages: ["/", "/about", "/products", "/contact"],
  viewports: [
    { width: 1920, height: 1080 },
    { width: 1366, height: 768 },
    { width: 375, height: 667 }
  ],
  threshold: 0.2
});
```

### **Component Screenshot Testing**

```javascript
// Test individual components
await playwright.screenshotComponents({
  url: "https://your-website.com",
  components: [
    { selector: ".header", name: "header" },
    { selector: ".navigation", name: "nav" },
    { selector: ".hero-section", name: "hero" },
    { selector: ".footer", name: "footer" }
  ]
});
```

## 🛡️ **Security Testing**

### **XSS Vulnerability Testing**

```javascript
// Test for XSS vulnerabilities
await playwright.testXSS({
  url: "https://your-website.com",
  forms: ["#search-form", "#contact-form", "#login-form"],
  payloads: [
    "<script>alert('XSS')</script>",
    "javascript:alert('XSS')",
    "<img src=x onerror=alert('XSS')>"
  ]
});
```

### **Authentication Testing**

```javascript
// Test authentication flows
await playwright.testAuthentication({
  loginUrl: "https://your-website.com/login",
  credentials: {
    valid: { username: "testuser", password: "testpass" },
    invalid: { username: "invalid", password: "wrong" }
  },
  protectedUrls: ["/dashboard", "/profile", "/settings"]
});
```

## 📊 **API Testing Integration**

### **API Response Validation**

```javascript
// Test API endpoints through UI interactions
await playwright.testAPIIntegration({
  url: "https://your-website.com",
  interactions: [
    {
      action: "click",
      selector: ".load-more",
      expectAPI: {
        url: "/api/posts",
        method: "GET",
        status: 200
      }
    }
  ]
});
```

### **Real-time Data Testing**

```javascript
// Test real-time features
await playwright.testRealTimeFeatures({
  url: "https://your-chat-app.com",
  scenarios: [
    { action: "sendMessage", text: "Hello World" },
    { action: "expectMessage", text: "Hello World", timeout: 5000 }
  ]
});
```
