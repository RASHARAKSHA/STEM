const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');
const path = require('path');
const fs = require('fs');

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));

// Serve all static files (HTML, CSS, JS, Images) from the project directory
app.use(express.static(__dirname));

// Database setup: SQLite with a JSON file fallback
const DB_FILE = path.join(__dirname, 'database.sqlite');
const FALLBACK_FILE = path.join(__dirname, 'feedback.json');
let dbMode = 'SQLite';
let db = null;

try {
  const sqlite3 = require('sqlite3').verbose();
  
  db = new sqlite3.Database(DB_FILE, (err) => {
    if (err) {
      console.error('Error connecting to SQLite database, switching to JSON fallback:', err.message);
      initializeFallback();
    } else {
      console.log('Connected to SQLite database successfully.');
      // Create feedback table if it doesn't exist
      db.run(`
        CREATE TABLE IF NOT EXISTS feedback (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          email TEXT NOT NULL,
          role TEXT NOT NULL,
          feedback_type TEXT NOT NULL,
          rating INTEGER NOT NULL,
          comments TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      `, (tableErr) => {
        if (tableErr) {
          console.error('Error creating SQLite table, switching to JSON fallback:', tableErr.message);
          dbMode = 'JSON';
        } else {
          dbMode = 'SQLite';
        }
      });
    }
  });
} catch (loadError) {
  console.warn('\n--- DATABASE WARNING ---');
  console.warn('sqlite3 package could not be loaded (likely missing build tools on Windows).');
  console.warn('Automatically switching to JSON file fallback database (feedback.json).');
  console.warn('-------------------------\n');
  initializeFallback();
}

function initializeFallback() {
  dbMode = 'JSON';
  // Ensure the fallback JSON file exists
  if (!fs.existsSync(FALLBACK_FILE)) {
    fs.writeFileSync(FALLBACK_FILE, JSON.stringify([], null, 2), 'utf8');
  }
}

// API endpoint to handle feedback submission
app.post('/api/feedback', (req, res) => {
  const { name, email, role, feedback_type, rating, comments } = req.body;

  // Simple server-side validation
  if (!name || !email || !role || !feedback_type || !rating || !comments) {
    return res.status(400).json({
      success: false,
      message: 'All form fields are required.'
    });
  }

  const createdAt = new Date().toISOString();

  if (dbMode === 'SQLite') {
    // Save to SQLite database
    const sql = `
      INSERT INTO feedback (name, email, role, feedback_type, rating, comments, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `;
    const params = [name, email, role, feedback_type, parseInt(rating), comments, createdAt];

    db.run(sql, params, function (err) {
      if (err) {
        console.error('SQL Insert Error:', err.message);
        return res.status(500).json({
          success: false,
          message: 'Failed to save feedback to SQL database.'
        });
      }
      console.log(`[SQL Database] Feedback from ${name} saved successfully with ID ${this.lastID}`);
      res.status(201).json({
        success: true,
        message: 'Feedback submitted and stored in the SQLite database table successfully!',
        id: this.lastID
      });
    });
  } else {
    // Save to fallback JSON file database
    try {
      const fileData = fs.readFileSync(FALLBACK_FILE, 'utf8');
      const feedbackList = JSON.parse(fileData);
      
      const newFeedback = {
        id: feedbackList.length > 0 ? feedbackList[feedbackList.length - 1].id + 1 : 1,
        name,
        email,
        role,
        feedback_type,
        rating: parseInt(rating),
        comments,
        created_at: createdAt
      };
      
      feedbackList.push(newFeedback);
      fs.writeFileSync(FALLBACK_FILE, JSON.stringify(feedbackList, null, 2), 'utf8');
      
      console.log(`[JSON Fallback] Feedback from ${name} saved successfully to feedback.json with ID ${newFeedback.id}`);
      res.status(201).json({
        success: true,
        message: 'Feedback submitted and stored in the JSON database successfully!',
        id: newFeedback.id
      });
    } catch (fsError) {
      console.error('Fallback Write Error:', fsError.message);
      res.status(500).json({
        success: false,
        message: 'Failed to save feedback to local file database.'
      });
    }
  }
});

// GET endpoint to view submissions (useful for verification/debugging)
app.get('/api/feedback', (req, res) => {
  if (dbMode === 'SQLite') {
    db.all('SELECT * FROM feedback ORDER BY id DESC', [], (err, rows) => {
      if (err) {
        return res.status(500).json({ success: false, error: err.message });
      }
      res.json({ success: true, dbMode, data: rows });
    });
  } else {
    try {
      const fileData = fs.readFileSync(FALLBACK_FILE, 'utf8');
      const feedbackList = JSON.parse(fileData);
      res.json({ success: true, dbMode, data: feedbackList.reverse() });
    } catch (err) {
      res.status(500).json({ success: false, error: err.message });
    }
  }
});

// Fallback to serving index.html for undefined frontend routes
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

// Start the server
app.listen(PORT, () => {
  console.log(`\n==================================================`);
  console.log(`  Horizon Academy Portal is running locally!`);
  console.log(`  Access the site at: http://localhost:${PORT}`);
  console.log(`  Database Engine: ${dbMode}`);
  console.log(`==================================================\n`);
});
