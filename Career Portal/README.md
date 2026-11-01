# Career Portal

An enterprise-grade, accessible, multi-step job application portal and recruitment console built with vanilla HTML5, CSS3, JavaScript, and an optional lightweight PowerShell backend.

---

## Key Features

### 1. Candidate Application Portal (6-Step Stepper)
- **Step 1: Account & Authentication** - Tier selection, username, email check for returning candidates, live password strength meter with client-side rules.
- **Step 2: Personal Identification** - Full name, gender selection, birthdate with automatic age calculation, drag-and-drop profile portrait uploader.
- **Step 3: Professional Background** - Drag-and-drop resume upload, cover note/bio, contact number, portfolio link, office preferences.
- **Step 4: Role & Competencies** - Target position selection, multilingual capabilities, custom theme accents, confidence/skill sliders.
- **Step 5: Availability & Preferences** - Working style (Remote, Hybrid, Onsite), notification opt-in, interview scheduling slots, target start date.
- **Step 6: Review & Final Submission** - Single-page full details preview with print-to-PDF support, legal consent agreements, cryptographic SHA-256 payload integrity hashing.

### 2. Recruiter & Talent Acquisition Console
- **Pipeline Dashboard** - Real-time counts across stages: Applied, Screening, Interview, Shortlisted, and Offer.
- **Dossier Modal** - Detailed candidate inspection view including technical/cultural ratings, recruiter notes, and document previews.
- **Applicant Telemetry & System Metadata Card** - Captures client IP, timezone/approximate region, device/hardware specs, CPU/RAM stats, and session duration.
- **Pipeline Data Export** - Export full applicant pipeline to JSON at any time.

### 3. Web APIs Utilized
- **HTML5 Drag & Drop API + File API**: Interactive upload dropzones with keyboard accessibility.
- **Web Crypto API**: Dynamic CSRF token generation (`crypto.randomUUID()`) and client-side SHA-256 data integrity verification.
- **HTML5 Geolocation & Internationalization API (`Intl`)**: Timezone, region, and localization detection.
- **Page Visibility API**: Silent draft auto-saving when switching browser tabs or windows.
- **Online/Offline Network Detection**: Automatic banner alerts and offline caching with localStorage synchronization.
- **Asynchronous Clipboard & Web Share API**: One-click sharing and copying of application reference IDs.

---

## Quick Start

### Standalone Mode (Browser-only)
Open `index.html` directly in any modern web browser. All features, validation, storage, and preview work immediately using browser `localStorage`.

### Local Server Mode (PowerShell Backend)
To enable automatic filesystem persistence into the `JobApplications/` folder and real socket-level remote IP capture:

```powershell
powershell -ExecutionPolicy Bypass -File server.ps1
```

Then visit:
```
http://localhost:8080/
```

---

## Repository Structure

```
Career Portal/
  index.html                    - Main Career Portal application
  Application.html              - Application form & career portal template
  server.ps1                    - Lightweight PowerShell REST server & API
  README.md                     - Project documentation
  images/                       - SVG icons and visual assets
    avatar-line.svg
    favicon.svg
    form-icon.svg
    submit-button-line.svg
    terms-shield-line.svg
  JobApplications/              - Stored applications & metadata records
    202611011815_1.json         - Sample seed candidate record
    index.json                  - Fast lookup application index
```

---

## License
This project is open-source and available under the [MIT License](../LICENSE). Free to use for personal and commercial applications.
