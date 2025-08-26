;; Deadline Tracking Contract
;; Monitors prosecution deadlines and provides automated alerts

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-DEADLINE-NOT-FOUND (err u201))
(define-constant ERR-INVALID-DEADLINE-TYPE (err u202))
(define-constant ERR-INVALID-DATE (err u203))
(define-constant ERR-DEADLINE-PASSED (err u204))
(define-constant ERR-EXTENSION-NOT-ALLOWED (err u205))
(define-constant ERR-INVALID-PRIORITY (err u206))
(define-constant ERR-APPLICATION-NOT-FOUND (err u207))

;; Deadline Types
(define-constant DEADLINE-OFFICE-ACTION-RESPONSE u1)
(define-constant DEADLINE-FILING-RESPONSE u2)
(define-constant DEADLINE-EXAMINATION-REQUEST u3)
(define-constant DEADLINE-MAINTENANCE-FEE u4)
(define-constant DEADLINE-RENEWAL u5)
(define-constant DEADLINE-APPEAL u6)
(define-constant DEADLINE-PUBLICATION u7)
(define-constant DEADLINE-SEARCH-REPORT u8)

;; Priority Levels
(define-constant PRIORITY-LOW u1)
(define-constant PRIORITY-MEDIUM u2)
(define-constant PRIORITY-HIGH u3)
(define-constant PRIORITY-CRITICAL u4)

;; Status Types
(define-constant STATUS-ACTIVE u1)
(define-constant STATUS-COMPLETED u2)
(define-constant STATUS-EXTENDED u3)
(define-constant STATUS-MISSED u4)
(define-constant STATUS-CANCELLED u5)

;; User Roles (matching ip-application contract)
(define-constant ROLE-ADMIN u1)
(define-constant ROLE-ATTORNEY u2)
(define-constant ROLE-PARALEGAL u3)
(define-constant ROLE-CLIENT u4)

;; Data Variables
(define-data-var next-deadline-id uint u1)
(define-data-var alert-threshold-days uint u30)

;; Data Maps
(define-map deadlines
  { deadline-id: uint }
  {
    application-id: uint,
    deadline-type: uint,
    title: (string-ascii 256),
    description: (string-ascii 512),
    due-date: uint,
    original-due-date: uint,
    priority: uint,
    status: uint,
    assigned-to: principal,
    created-by: principal,
    extensions-used: uint,
    max-extensions: uint,
    extension-period-days: uint,
    completion-date: (optional uint),
    notes: (string-ascii 1024),
    created-at: uint,
    updated-at: uint
  }
)

(define-map deadline-alerts
  { deadline-id: uint, alert-id: uint }
  {
    alert-type: (string-ascii 64),
    alert-date: uint,
    days-before-due: uint,
    recipient: principal,
    message: (string-ascii 512),
    sent: bool,
    acknowledged: bool,
    acknowledged-by: (optional principal),
    acknowledged-at: (optional uint)
  }
)

(define-map deadline-extensions
  { deadline-id: uint, extension-id: uint }
  {
    requested-by: principal,
    approved-by: (optional principal),
    request-date: uint,
    approval-date: (optional uint),
    extension-days: uint,
    reason: (string-ascii 512),
    status: (string-ascii 32),
    notes: (string-ascii 512)
  }
)

(define-map user-roles
  { user: principal }
  { role: uint }
)

(define-map deadline-sequences
  { deadline-id: uint }
  { alert-sequence: uint, extension-sequence: uint }
)

(define-map application-deadlines
  { application-id: uint }
  { deadline-count: uint }
)

;; Authorization Functions
(define-private (is-authorized (user principal) (required-role uint))
  (let ((user-role (get role (map-get? user-roles { user: user }))))
    (match user-role
      role (or (is-eq role ROLE-ADMIN) (>= role required-role))
      false
    )
  )
)

(define-private (is-admin (user principal))
  (is-authorized user ROLE-ADMIN)
)

(define-private (can-manage-deadline (user principal) (deadline-id uint))
  (match (map-get? deadlines { deadline-id: deadline-id })
    deadline (or
      (is-admin user)
      (is-eq user (get assigned-to deadline))
      (is-eq user (get created-by deadline))
    )
    false
  )
)

;; Public Functions

;; Set user role (admin only)
(define-public (set-user-role (user principal) (role uint))
  (begin
    (asserts! (is-admin tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= role u1) (<= role u4)) ERR-INVALID-PRIORITY)
    (ok (map-set user-roles { user: user } { role: role }))
  )
)

;; Create new deadline
(define-public (create-deadline
  (application-id uint)
  (deadline-type uint)
  (title (string-ascii 256))
  (description (string-ascii 512))
  (due-date uint)
  (priority uint)
  (assigned-to principal)
  (max-extensions uint)
  (extension-period-days uint)
)
  (let (
    (deadline-id (var-get next-deadline-id))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    (asserts! (is-authorized tx-sender ROLE-PARALEGAL) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= deadline-type u1) (<= deadline-type u8)) ERR-INVALID-DEADLINE-TYPE)
    (asserts! (and (>= priority u1) (<= priority u4)) ERR-INVALID-PRIORITY)
    (asserts! (> due-date current-time) ERR-INVALID-DATE)
    (asserts! (> (len title) u0) ERR-INVALID-DATE)

    ;; Create deadline
    (map-set deadlines
      { deadline-id: deadline-id }
      {
        application-id: application-id,
        deadline-type: deadline-type,
        title: title,
        description: description,
        due-date: due-date,
        original-due-date: due-date,
        priority: priority,
        status: STATUS-ACTIVE,
        assigned-to: assigned-to,
        created-by: tx-sender,
        extensions-used: u0,
        max-extensions: max-extensions,
        extension-period-days: extension-period-days,
        completion-date: none,
        notes: "",
        created-at: current-time,
        updated-at: current-time
      }
    )

    ;; Initialize sequences
    (map-set deadline-sequences
      { deadline-id: deadline-id }
      { alert-sequence: u0, extension-sequence: u0 }
    )

    ;; Update application deadline count
    (let ((current-count (default-to u0 (get deadline-count (map-get? application-deadlines { application-id: application-id })))))
      (map-set application-deadlines
        { application-id: application-id }
        { deadline-count: (+ current-count u1) }
      )
    )

    ;; Create automatic alerts
    (unwrap-panic (create-automatic-alerts deadline-id due-date assigned-to))

    ;; Increment counter
    (var-set next-deadline-id (+ deadline-id u1))
    (ok deadline-id)
  )
)

;; Update deadline status
(define-public (update-deadline-status (deadline-id uint) (new-status uint) (notes (string-ascii 1024)))
  (match (map-get? deadlines { deadline-id: deadline-id })
    deadline (let (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (completion-date (if (is-eq new-status STATUS-COMPLETED) (some current-time) none))
    )
      (asserts! (can-manage-deadline tx-sender deadline-id) ERR-NOT-AUTHORIZED)
      (asserts! (and (>= new-status u1) (<= new-status u5)) ERR-INVALID-DEADLINE-TYPE)

      ;; Update deadline
      (map-set deadlines
        { deadline-id: deadline-id }
        (merge deadline {
          status: new-status,
          completion-date: completion-date,
          notes: notes,
          updated-at: current-time
        })
      )
      (ok true)
    )
    ERR-DEADLINE-NOT-FOUND
  )
)

;; Request deadline extension
(define-public (request-extension
  (deadline-id uint)
  (extension-days uint)
  (reason (string-ascii 512))
)
  (match (map-get? deadlines { deadline-id: deadline-id })
    deadline (match (map-get? deadline-sequences { deadline-id: deadline-id })
      sequences (let (
        (extension-id (+ (get extension-sequence sequences) u1))
        (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
        (current-extensions (get extensions-used deadline))
        (max-extensions (get max-extensions deadline))
      )
        (asserts! (can-manage-deadline tx-sender deadline-id) ERR-NOT-AUTHORIZED)
        (asserts! (< current-extensions max-extensions) ERR-EXTENSION-NOT-ALLOWED)
        (asserts! (> extension-days u0) ERR-INVALID-DATE)

        ;; Create extension request
        (map-set deadline-extensions
          { deadline-id: deadline-id, extension-id: extension-id }
          {
            requested-by: tx-sender,
            approved-by: none,
            request-date: current-time,
            approval-date: none,
            extension-days: extension-days,
            reason: reason,
            status: "pending",
            notes: ""
          }
        )

        ;; Update sequence
        (map-set deadline-sequences
          { deadline-id: deadline-id }
          (merge sequences { extension-sequence: extension-id })
        )

        (ok extension-id)
      )
      ERR-DEADLINE-NOT-FOUND
    )
    ERR-DEADLINE-NOT-FOUND
  )
)

;; Approve deadline extension
(define-public (approve-extension
  (deadline-id uint)
  (extension-id uint)
  (approved bool)
  (notes (string-ascii 512))
)
  (match (map-get? deadline-extensions { deadline-id: deadline-id, extension-id: extension-id })
    extension (match (map-get? deadlines { deadline-id: deadline-id })
      deadline (let (
        (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
        (new-due-date (if approved (+ (get due-date deadline) (get extension-days extension)) (get due-date deadline)))
        (new-extensions-used (if approved (+ (get extensions-used deadline) u1) (get extensions-used deadline)))
        (new-status (if approved "approved" "rejected"))
      )
        (asserts! (is-authorized tx-sender ROLE-ATTORNEY) ERR-NOT-AUTHORIZED)

        ;; Update extension
        (map-set deadline-extensions
          { deadline-id: deadline-id, extension-id: extension-id }
          (merge extension {
            approved-by: (some tx-sender),
            approval-date: (some current-time),
            status: new-status,
            notes: notes
          })
        )

        ;; Update deadline if approved
        (if approved
          (map-set deadlines
            { deadline-id: deadline-id }
            (merge deadline {
              due-date: new-due-date,
              extensions-used: new-extensions-used,
              status: STATUS-EXTENDED,
              updated-at: current-time
            })
          )
          true
        )

        (ok approved)
      )
      ERR-DEADLINE-NOT-FOUND
    )
    ERR-DEADLINE-NOT-FOUND
  )
)

;; Create alert
(define-public (create-alert
  (deadline-id uint)
  (alert-type (string-ascii 64))
  (days-before-due uint)
  (recipient principal)
  (message (string-ascii 512))
)
  (match (map-get? deadlines { deadline-id: deadline-id })
    deadline (match (map-get? deadline-sequences { deadline-id: deadline-id })
      sequences (let (
        (alert-id (+ (get alert-sequence sequences) u1))
        (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
        (alert-date (- (get due-date deadline) (* days-before-due u86400)))
      )
        (asserts! (can-manage-deadline tx-sender deadline-id) ERR-NOT-AUTHORIZED)

        ;; Create alert
        (map-set deadline-alerts
          { deadline-id: deadline-id, alert-id: alert-id }
          {
            alert-type: alert-type,
            alert-date: alert-date,
            days-before-due: days-before-due,
            recipient: recipient,
            message: message,
            sent: false,
            acknowledged: false,
            acknowledged-by: none,
            acknowledged-at: none
          }
        )

        ;; Update sequence
        (map-set deadline-sequences
          { deadline-id: deadline-id }
          (merge sequences { alert-sequence: alert-id })
        )

        (ok alert-id)
      )
      ERR-DEADLINE-NOT-FOUND
    )
    ERR-DEADLINE-NOT-FOUND
  )
)

;; Acknowledge alert
(define-public (acknowledge-alert (deadline-id uint) (alert-id uint))
  (match (map-get? deadline-alerts { deadline-id: deadline-id, alert-id: alert-id })
    alert (let (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
      (asserts! (is-eq tx-sender (get recipient alert)) ERR-NOT-AUTHORIZED)

      (map-set deadline-alerts
        { deadline-id: deadline-id, alert-id: alert-id }
        (merge alert {
          acknowledged: true,
          acknowledged-by: (some tx-sender),
          acknowledged-at: (some current-time)
        })
      )
      (ok true)
    )
    ERR-DEADLINE-NOT-FOUND
  )
)

;; Set alert threshold
(define-public (set-alert-threshold (days uint))
  (begin
    (asserts! (is-admin tx-sender) ERR-NOT-AUTHORIZED)
    (var-set alert-threshold-days days)
    (ok true)
  )
)

;; Private Functions

;; Create automatic alerts for new deadline
(define-private (create-automatic-alerts (deadline-id uint) (due-date uint) (assigned-to principal))
  (let (
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    ;; Create 30-day alert
    (unwrap-panic (create-alert deadline-id "30-day-warning" u30 assigned-to "Deadline approaching in 30 days"))
    ;; Create 7-day alert
    (unwrap-panic (create-alert deadline-id "7-day-warning" u7 assigned-to "Deadline approaching in 7 days"))
    ;; Create 1-day alert
    (unwrap-panic (create-alert deadline-id "1-day-warning" u1 assigned-to "Deadline approaching in 1 day"))
    (ok true)
  )
)

;; Read-only Functions

;; Get deadline details
(define-read-only (get-deadline (deadline-id uint))
  (map-get? deadlines { deadline-id: deadline-id })
)

;; Get deadline alert
(define-read-only (get-alert (deadline-id uint) (alert-id uint))
  (map-get? deadline-alerts { deadline-id: deadline-id, alert-id: alert-id })
)

;; Get deadline extension
(define-read-only (get-extension (deadline-id uint) (extension-id uint))
  (map-get? deadline-extensions { deadline-id: deadline-id, extension-id: extension-id })
)

;; Get user role
(define-read-only (get-user-role (user principal))
  (map-get? user-roles { user: user })
)

;; Get application deadline count
(define-read-only (get-application-deadline-count (application-id uint))
  (map-get? application-deadlines { application-id: application-id })
)

;; Get deadline sequences
(define-read-only (get-deadline-sequences (deadline-id uint))
  (map-get? deadline-sequences { deadline-id: deadline-id })
)

;; Get next deadline ID
(define-read-only (get-next-deadline-id)
  (var-get next-deadline-id)
)

;; Get alert threshold
(define-read-only (get-alert-threshold)
  (var-get alert-threshold-days)
)

;; Check if deadline is overdue
(define-read-only (is-deadline-overdue (deadline-id uint))
  (match (map-get? deadlines { deadline-id: deadline-id })
    deadline (let (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (due-date (get due-date deadline))
      (status (get status deadline))
    )
      (and (> current-time due-date) (is-eq status STATUS-ACTIVE))
    )
    false
  )
)

;; Check management permission
(define-read-only (check-deadline-management-permission (user principal) (deadline-id uint))
  (can-manage-deadline user deadline-id)
)
