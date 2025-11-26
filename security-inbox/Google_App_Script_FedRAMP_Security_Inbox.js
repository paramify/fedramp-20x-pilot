// FedRAMP Security Inbox - Gmail to Slack Notification Script
// Implements filtering based on FedRAMP Security Inbox standard 
// https://www.fedramp.gov/docs/fedramp-security-inbox/
// Version: 1.0

// =============================================================================
// CONFIGURATION
// =============================================================================

const CONFIG = {
    // Slack webhook URL - Replace with your actual webhook
    slackWebhookUrl: '<YOUR_SLACK_WEBHOOK_URL>',
    
    // Set to your CSO's impact level: 'high', 'moderate', or 'low'
    impactLevel: 'moderate',
    
    // Labels for organizing emails
    processedLabel: 'notified-to-slack',
    labels: {
      emergency: 'FedRAMP/Emergency',
      emergencyTest: 'FedRAMP/Emergency-Test',
      important: 'FedRAMP/Important',
      general: 'FedRAMP/General'
    },
    
    // Test mode configuration
    testMode: {
      enabled: false,  // Set to true to enable test mode
      testLabel: 'fedramp-test-emails'  // Label to apply to test emails
    }
  };
  
  // =============================================================================
  // MAIN FUNCTIONS
  // =============================================================================
  
  /**
   * Main function - run this on a time-based trigger
   * Checks all FedRAMP email categories
   */
  function checkFedRAMPEmails() {
    checkEmergencyTestEmails(); // check Emergency Test BEFORE Emergency to prevent false matches
    checkEmergencyEmails();
    checkImportantEmails();
    checkGeneralFedRAMPEmails();
  }
  
  /**
   * Check for Emergency emails (highest priority)
   * FRR-FSI-03: Emergency messages come from fedramp_security@gsa.gov OR fedramp_security@fedramp.gov
   */
  function checkEmergencyEmails() {
    var searchQuery = buildSearchQuery(
      '(from:fedramp_security@gsa.gov OR from:fedramp_security@fedramp.gov)',
      'subject:"Emergency" -subject:"Emergency Test"'
    );
    
    var threads = GmailApp.search(searchQuery);
    
    threads.forEach(function(thread) {
      var message = thread.getMessages()[0];
      var subject = message.getSubject();
      var receivedDate = message.getDate();
      var deadline = calculateDeadline(receivedDate, CONFIG.impactLevel);
      
      var payload = {
        text: '🚨🚨 *FEDRAMP EMERGENCY* 🚨🚨\n\n' +
              '*Subject:* ' + subject + '\n' +
              '*Received:* ' + formatTimestamp(receivedDate) + '\n' +
              '*Deadline:* ' + formatDeadline(deadline) + '\n\n' +
              '⚠️ *FRR-FSI-14:* Response required within specified timeframe.\n' +
              '⚠️ *FRR-FSI-15:* Route to senior security official.\n\n' +
              '📧 <https://mail.google.com/mail/u/0/#inbox/' + thread.getId() + '|View Email in Gmail>\n\n' +
              // '_Create GitLab incident immediately._' +
              (CONFIG.testMode.enabled ? '\n\n⚙️ _TEST MODE - No actual FedRAMP email_' : '')
      };
      
      sendSlackNotification(payload);
      applyLabels(thread, CONFIG.labels.emergency);
      
      Logger.log('Processed Emergency email: ' + subject);
    });
  }

/**
 * Check for Emergency Test emails
 * Run before checkEmergencyEmails to prevent "Emergency Test" matching "Emergency"
 * FRR-FSI-02 and FRR-FSI-04: FedRAMP conducts periodic tests
 */
function checkEmergencyTestEmails() {
    var searchQuery = buildSearchQuery(
      '(from:fedramp_security@gsa.gov OR from:fedramp_security@fedramp.gov)',
      'subject:"Emergency Test"'
    );
    
    var threads = GmailApp.search(searchQuery);
    
    threads.forEach(function(thread) {
      var message = thread.getMessages()[0];
      var subject = message.getSubject();
      var receivedDate = message.getDate();
      var deadline = calculateDeadline(receivedDate, CONFIG.impactLevel);
      
      var payload = {
        text: '🧪🚨 *FEDRAMP EMERGENCY TEST* 🚨🧪\n\n' +
              '*Subject:* ' + subject + '\n' +
              '*Received:* ' + formatTimestamp(receivedDate) + '\n' +
              '*Deadline:* ' + formatDeadline(deadline) + '\n\n' +
              '⚠️ *FRR-FSI-14:* This test requires the same response as a real emergency.\n' +
              '📊 *FRR-FSI-08:* FedRAMP may publicly track response times.\n\n' +
              '📧 <https://mail.google.com/mail/u/0/#inbox/' + thread.getId() + '|View Email in Gmail>\n\n' +
              // '_Create GitLab incident to track response time._' +
              (CONFIG.testMode.enabled ? '\n\n⚙️ _TEST MODE - No actual FedRAMP email_' : '')
      };
      
      sendSlackNotification(payload);
      applyLabels(thread, CONFIG.labels.emergencyTest);
      
      Logger.log('Processed Emergency Test email: ' + subject);
    });
  }
  
  /**
   * Check for Important emails
   * FRR-FSI-02: Important messages from any @fedramp.gov or @gsa.gov address
   */
  function checkImportantEmails() {
    var searchQuery = buildSearchQuery(
      '(from:@fedramp.gov OR from:@gsa.gov)',
      'subject:"Important"'
    );
    
    var threads = GmailApp.search(searchQuery);
    
    threads.forEach(function(thread) {
      var message = thread.getMessages()[0];
      var subject = message.getSubject();
      var receivedDate = message.getDate();
      
      var payload = {
        text: '📋 *FedRAMP Important Message*\n\n' +
              '*Subject:* ' + subject + '\n' +
              '*Received:* ' + formatTimestamp(receivedDate) + '\n\n' +
              '📌 *FRR-FSI-16:* Response recommended within timeframe specified in message.\n\n' +
              '📧 <https://mail.google.com/mail/u/0/#inbox/' + thread.getId() + '|View Email in Gmail>' +
              (CONFIG.testMode.enabled ? '\n\n⚙️ _TEST MODE - No actual FedRAMP email_' : '')
      };
      
      sendSlackNotification(payload);
      applyLabels(thread, CONFIG.labels.important);
      
      Logger.log('Processed Important email: ' + subject);
    });
  }
  
  /**
   * Check for General FedRAMP emails (catch-all)
   * Emails from FedRAMP/GSA without criticality designators
   */
  function checkGeneralFedRAMPEmails() {
    var searchQuery = buildSearchQuery(
      '(from:@fedramp.gov OR from:@gsa.gov)',
      '-subject:"Emergency" -subject:"Emergency Test" -subject:"Important"'
    );
    
    // Also exclude already-labeled emails
    searchQuery += ' -label:' + CONFIG.labels.emergency.replace('/', '-').toLowerCase() +
                   ' -label:' + CONFIG.labels.emergencyTest.replace('/', '-').toLowerCase() +
                   ' -label:' + CONFIG.labels.important.replace('/', '-').toLowerCase();
    
    var threads = GmailApp.search(searchQuery);
    
    threads.forEach(function(thread) {
      var message = thread.getMessages()[0];
      var subject = message.getSubject();
      var receivedDate = message.getDate();
      
      var payload = {
        text: '📬 *FedRAMP General Message*\n\n' +
              '*Subject:* ' + subject + '\n' +
              '*Received:* ' + formatTimestamp(receivedDate) + '\n\n' +
              '📧 <https://mail.google.com/mail/u/0/#inbox/' + thread.getId() + '|View Email in Gmail>' +
              (CONFIG.testMode.enabled ? '\n\n⚙️ _TEST MODE - No actual FedRAMP email_' : '')
      };
      
      sendSlackNotification(payload);
      applyLabels(thread, CONFIG.labels.general);
      
      Logger.log('Processed General email: ' + subject);
    });
  }
  
  // =============================================================================
  // DEADLINE CALCULATION FUNCTIONS
  // =============================================================================
  
  /**
   * Calculate absolute deadline based on impact level and received date
   * FRR-FSI-06:
   *   High: within 12 hours
   *   Moderate: by 3:00 PM ET on the 2nd business day
   *   Low: by 3:00 PM ET on the 3rd business day
   */
  function calculateDeadline(receivedDate, impactLevel) {
    var deadline = new Date(receivedDate);
    
    switch (impactLevel) {
      case 'high':
        deadline.setHours(deadline.getHours() + 12);
        break;
        
      case 'moderate':
        deadline = getBusinessDayDeadline(receivedDate, 2);
        break;
        
      case 'low':
        deadline = getBusinessDayDeadline(receivedDate, 3);
        break;
    }
    
    return deadline;
  }
  
  /**
   * Get deadline at 3:00 PM ET on the Nth business day after receivedDate
   */
  function getBusinessDayDeadline(receivedDate, businessDays) {
    var deadline = new Date(receivedDate);
    var daysAdded = 0;
    
    while (daysAdded < businessDays) {
      deadline.setDate(deadline.getDate() + 1);
      
      // Skip weekends (0 = Sunday, 6 = Saturday)
      var dayOfWeek = deadline.getDay();
      if (dayOfWeek !== 0 && dayOfWeek !== 6) {
        daysAdded++;
      }
    }
    
    // Set to 3:00 PM Eastern Time
    deadline = setToEasternTime(deadline, 15, 0);
    
    return deadline;
  }
  
  /**
   * Set time to specific hour/minute in Eastern Time
   * Handles EST (UTC-5) and EDT (UTC-4) based on date
   */
  function setToEasternTime(date, hour, minute) {
    // Determine if date is in EDT or EST
    var jan = new Date(date.getFullYear(), 0, 1);
    var jul = new Date(date.getFullYear(), 6, 1);
    var stdOffset = Math.max(jan.getTimezoneOffset(), jul.getTimezoneOffset());
    var isDST = date.getTimezoneOffset() < stdOffset;
    
    // Eastern Time offset: UTC-4 (EDT) or UTC-5 (EST)
    var etOffsetHours = isDST ? -4 : -5;
    
    // Create date at 3:00 PM ET
    var utcHour = hour - etOffsetHours;
    date.setUTCHours(utcHour, minute, 0, 0);
    
    return date;
  }
  
  // =============================================================================
  // HELPER FUNCTIONS
  // =============================================================================
  
  /**
   * Build search query with test mode support
   */
  function buildSearchQuery(fromClause, subjectClause) {
    var query;
    
    if (CONFIG.testMode.enabled) {
      // In test mode, search for emails with test label instead of actual FedRAMP senders
      query = 'label:' + CONFIG.testMode.testLabel + ' ' + subjectClause;
    } else {
      // Production mode - search for actual FedRAMP emails
      query = fromClause + ' ' + subjectClause;
    }
    
    // Always exclude already-processed emails
    query += ' -label:' + CONFIG.processedLabel;
    
    return query;
  }
  
  /**
   * Send notification to Slack
   */
  function sendSlackNotification(payload) {
    var options = {
      method: 'post',
      contentType: 'application/json',
      payload: JSON.stringify(payload),
      muteHttpExceptions: true
    };
    
    try {
      var response = UrlFetchApp.fetch(CONFIG.slackWebhookUrl, options);
      Logger.log('Slack notification sent. Response: ' + response.getResponseCode());
    } catch (error) {
      Logger.log('Error sending Slack notification: ' + error.toString());
    }
  }
  
  /**
   * Apply labels to processed thread
   */
  function applyLabels(thread, categoryLabel) {
    // Apply processed label
    var processedLabel = GmailApp.getUserLabelByName(CONFIG.processedLabel) || 
                         GmailApp.createLabel(CONFIG.processedLabel);
    processedLabel.addToThread(thread);
    
    // Apply category label
    var catLabel = GmailApp.getUserLabelByName(categoryLabel) || 
                   GmailApp.createLabel(categoryLabel);
    catLabel.addToThread(thread);
  }
  
  /**
   * Format timestamp for display (human-readable)
   */
  function formatTimestamp(date) {
    var options = {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      year: 'numeric',
      hour: 'numeric',
      minute: '2-digit',
      timeZoneName: 'short'
    };
    
    return date.toLocaleString('en-US', options);
  }
  
  /**
   * Format deadline for display in Slack
   */
  function formatDeadline(deadline) {
    var options = {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit',
      timeZoneName: 'short'
    };
    
    return deadline.toLocaleString('en-US', options);
  }
  
  // =============================================================================
  // SETUP AND TEST FUNCTIONS
  // =============================================================================
  
  /**
   * Run once to create all required Gmail labels
   */
  function setupLabels() {
    var labelsCreated = [];
    
    // Create category labels
    Object.values(CONFIG.labels).forEach(function(labelName) {
      if (!GmailApp.getUserLabelByName(labelName)) {
        GmailApp.createLabel(labelName);
        labelsCreated.push(labelName);
      }
    });
    
    // Create processed label
    if (!GmailApp.getUserLabelByName(CONFIG.processedLabel)) {
      GmailApp.createLabel(CONFIG.processedLabel);
      labelsCreated.push(CONFIG.processedLabel);
    }
    
    // Create test label
    if (!GmailApp.getUserLabelByName(CONFIG.testMode.testLabel)) {
      GmailApp.createLabel(CONFIG.testMode.testLabel);
      labelsCreated.push(CONFIG.testMode.testLabel);
    }
    
    if (labelsCreated.length > 0) {
      Logger.log('Created labels: ' + labelsCreated.join(', '));
    } else {
      Logger.log('All labels already exist.');
    }
  }
  
  /**
   * Test the Slack webhook connection
   */
  function testSlackWebhook() {
    var payload = {
      text: '*FedRAMP Security Inbox - Webhook Test*\n\n' +
            'This is a test message from your FedRAMP Security Inbox automation.\n' +
            'Webhook is configured correctly!\n\n' +
            '*Configured Impact Level:* ' + CONFIG.impactLevel + '\n' +
            '*Test Mode:* ' + (CONFIG.testMode.enabled ? 'Enabled' : 'Disabled')
    };
    
    sendSlackNotification(payload);
    Logger.log('Test notification sent to Slack. Check your channel.');
  }
  
  /**
   * Test deadline calculation
   */
  function testDeadlineCalculation() {
    var now = new Date();
    
    Logger.log('Current time: ' + formatTimestamp(now));
    Logger.log('---');
    
    ['high', 'moderate', 'low'].forEach(function(level) {
      var deadline = calculateDeadline(now, level);
      Logger.log(level.toUpperCase() + ' deadline: ' + formatDeadline(deadline));
    });
  }
  
  /**
   * Enable test mode - run this to start testing
   */
  function enableTestMode() {
    Logger.log('=== TEST MODE INSTRUCTIONS ===');
    Logger.log('1. In the CONFIG object at the top of the script, set:');
    Logger.log('   testMode: { enabled: true, ... }');
    Logger.log('');
    Logger.log('2. Send yourself test emails with these subjects:');
    Logger.log('   - "Emergency - Test security alert"');
    Logger.log('   - "Emergency Test - Quarterly drill"');
    Logger.log('   - "Important - Policy update notification"');
    Logger.log('   - "General inquiry from FedRAMP"');
    Logger.log('');
    Logger.log('3. Apply the label "' + CONFIG.testMode.testLabel + '" to those emails');
    Logger.log('');
    Logger.log('4. Run checkFedRAMPEmails() to process them');
    Logger.log('');
    Logger.log('5. Check your Slack channel for notifications');
    Logger.log('');
    Logger.log('6. When done testing, set testMode.enabled back to false');
  }
  
  /**
   * Clean up test labels (removes processed label from test emails so you can retest)
   */
  function resetTestEmails() {
    var testLabel = GmailApp.getUserLabelByName(CONFIG.testMode.testLabel);
    var processedLabel = GmailApp.getUserLabelByName(CONFIG.processedLabel);
    
    if (!testLabel) {
      Logger.log('Test label not found. Run setupLabels() first.');
      return;
    }
    
    var threads = testLabel.getThreads();
    
    threads.forEach(function(thread) {
      // Remove processed label
      if (processedLabel) {
        processedLabel.removeFromThread(thread);
      }
      
      // Remove category labels
      Object.values(CONFIG.labels).forEach(function(labelName) {
        var label = GmailApp.getUserLabelByName(labelName);
        if (label) {
          label.removeFromThread(thread);
        }
      });
    });
    
    Logger.log('Reset ' + threads.length + ' test email(s). You can run checkFedRAMPEmails() again.');
  }