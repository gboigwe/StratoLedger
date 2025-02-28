;; StratoSense - Data Registry Contract (Commit 1)
;; Basic definitions, dataset storage, counter, and admin management

;; Error Codes
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-DATASET-NOT-FOUND (err u404))
(define-constant ERR-INVALID-PARAMS (err u400))
(define-constant ERR-METADATA-FROZEN (err u403))

;; Dataset Map: Stores each dataset with its metadata.
(define-map datasets
  { dataset-id: uint }
  {
    owner: principal,
    name: (string-utf8 100),
    description: (string-utf8 500),
    data-type: (string-utf8 50),
    collection-date: uint,
    altitude-min: uint,
    altitude-max: uint,
    latitude: int,
    longitude: int,
    ipfs-hash: (string-ascii 100),
    is-public: bool,
    metadata-frozen: bool,
    created-at: uint
  }
)

;; Counter for dataset IDs
(define-data-var dataset-counter uint u0)

;; Map for datasets by owner
(define-map datasets-by-owner
  { owner: principal }
  { dataset-ids: (list 1000 uint) }
)

;; Contract admin
(define-data-var contract-admin principal tx-sender)

;; Admin management functions
(define-read-only (get-contract-admin)
  (ok (var-get contract-admin))
)

(define-public (set-contract-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    (var-set contract-admin new-admin)
    (ok new-admin)
  )
)

;; Helper to check if the caller is the owner of a dataset
(define-private (is-dataset-owner (dataset-id uint))
  (let ((dataset (map-get? datasets { dataset-id: dataset-id })))
    (match dataset
      data (is-eq tx-sender (get owner data))
      false
    )
  )
)

;; Register a new atmospheric dataset
(define-public (register-dataset 
  (name (string-utf8 100))
  (description (string-utf8 500))
  (data-type (string-utf8 50))
  (collection-date uint)
  (altitude-min uint)
  (altitude-max uint)
  (latitude int)
  (longitude int)
  (ipfs-hash (string-ascii 100))
  (is-public bool))
  (let (
    (dataset-id (+ (var-get dataset-counter) u1))
    (owner-principal tx-sender)
    (current-time (unwrap-panic (get-block-info? time u0)))
  )
    ;; Validate parameters
    (asserts! (>= altitude-min u0) ERR-INVALID-PARAMS)
    (asserts! (>= altitude-max altitude-min) ERR-INVALID-PARAMS)
    (asserts! (and (>= latitude (* -90 1000000)) (<= latitude (* 90 1000000))) ERR-INVALID-PARAMS)
    (asserts! (and (>= longitude (* -180 1000000)) (<= longitude (* 180 1000000))) ERR-INVALID-PARAMS)
    
    ;; Register the dataset
    (map-set datasets
      { dataset-id: dataset-id }
      {
        owner: owner-principal,
        name: name,
        description: description,
        data-type: data-type,
        collection-date: collection-date,
        altitude-min: altitude-min,
        altitude-max: altitude-max,
        latitude: latitude,
        longitude: longitude,
        ipfs-hash: ipfs-hash,
        is-public: is-public,
        metadata-frozen: false,
        created-at: current-time
      }
    )
    
    ;; Update the owner's dataset list
    (let (
      (current-list (default-to { dataset-ids: (list) } (map-get? datasets-by-owner { owner: owner-principal })))
      (updated-list (append (get dataset-ids current-list) (list dataset-id)))
    )
      (map-set datasets-by-owner
        { owner: owner-principal }
        { dataset-ids: updated-list }
      )
    )
    
    (var-set dataset-counter dataset-id)
    (ok dataset-id)
  )
)

;; Update dataset metadata (only allowed if the caller is the owner and metadata is not frozen)
(define-public (update-dataset-metadata
  (dataset-id uint)
  (name (string-utf8 100))
  (description (string-utf8 500))
  (data-type (string-utf8 50))
  (is-public bool))
  (let ((dataset (unwrap! (map-get? datasets { dataset-id: dataset-id }) ERR-DATASET-NOT-FOUND)))
    (asserts! (is-dataset-owner dataset-id) ERR-NOT-AUTHORIZED)
    (asserts! (not (get metadata-frozen dataset)) ERR-METADATA-FROZEN)
    (map-set datasets
      { dataset-id: dataset-id }
      (merge dataset {
        name: name,
        description: description,
        data-type: data-type,
        is-public: is-public
      })
    )
    (ok true)
  )
)

;; Freeze dataset metadata (only the owner can freeze)
(define-public (freeze-dataset-metadata (dataset-id uint))
  (let ((dataset (unwrap! (map-get? datasets { dataset-id: dataset-id }) ERR-DATASET-NOT-FOUND)))
    (asserts! (is-dataset-owner dataset-id) ERR-NOT-AUTHORIZED)
    (map-set datasets
      { dataset-id: dataset-id }
      (merge dataset { metadata-frozen: true })
    )
    (ok true)
  )
)

;; Transfer dataset ownership to a new owner
(define-public (transfer-dataset (dataset-id uint) (new-owner principal))
  (let (
    (dataset (unwrap! (map-get? datasets { dataset-id: dataset-id }) ERR-DATASET-NOT-FOUND))
    (current-owner tx-sender)
  )
    (asserts! (is-dataset-owner dataset-id) ERR-NOT-AUTHORIZED)
    ;; Update the dataset's owner
    (map-set datasets
      { dataset-id: dataset-id }
      (merge dataset { owner: new-owner })
    )
    ;; Remove dataset from current owner's list
    (let (
      (current-list (default-to { dataset-ids: (list) } (map-get? datasets-by-owner { owner: current-owner })))
      (updated-current (filter (lambda (id) (not (is-eq id dataset-id))) (get dataset-ids current-list)))
    )
      (map-set datasets-by-owner { owner: current-owner } { dataset-ids: updated-current })
    )
    ;; Add dataset to the new owner's list
    (let (
      (new-list (default-to { dataset-ids: (list) } (map-get? datasets-by-owner { owner: new-owner })))
      (updated-new (append (get dataset-ids new-list) (list dataset-id)))
    )
      (map-set datasets-by-owner { owner: new-owner } { dataset-ids: updated-new })
    )
    (ok true)
  )
)

;; Get dataset information by ID
(define-read-only (get-dataset (dataset-id uint))
  (match (map-get? datasets { dataset-id: dataset-id })
    data (ok data)
    none (err ERR-DATASET-NOT-FOUND)
  )
)

;; Get all dataset IDs associated with a specific owner
(define-read-only (get-datasets-by-owner (owner principal))
  (let ((owner-data (map-get? datasets-by-owner { owner: owner })))
    (match owner-data
      data (ok (get dataset-ids data))
      none (ok (list))
    )
  )
)

;; Get the total number of datasets registered
(define-read-only (get-dataset-count)
  (ok (var-get dataset-counter))
)

;; Check if a dataset is public
(define-read-only (is-dataset-public (dataset-id uint))
  (match (map-get? datasets { dataset-id: dataset-id })
    data (ok (get is-public data))
    none (err ERR-DATASET-NOT-FOUND)
  )
)
