;; StratoSense - Data Registry Contract
;; This contract handles the registration of atmospheric datasets, maintains ownership information,
;; and manages the metadata associated with each dataset.

;; Error Codes
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-DATASET-EXISTS (err u409))
(define-constant ERR-DATASET-NOT-FOUND (err u404))
(define-constant ERR-INVALID-PARAMS (err u400))
(define-constant ERR-METADATA-FROZEN (err u403))

;; Define the data types for our registry
(define-map datasets
  { dataset-id: uint }
  {
    owner: principal,
    name: (string-utf8 100),
    description: (string-utf8 500),
    data-type: (string-utf8 50),
    collection-date: uint,
    altitude-min: uint, ;; in meters
    altitude-max: uint, ;; in meters
    latitude: int,      ;; scaled by 10^6
    longitude: int,     ;; scaled by 10^6
    ipfs-hash: (string-ascii 100),
    is-public: bool,
    metadata-frozen: bool,
    created-at: uint
  }
)

;; Keep track of dataset count
(define-data-var dataset-counter uint u0)

;; Keep track of datasets by owner
(define-map datasets-by-owner
  { owner: principal }
  { dataset-ids: (list 1000 uint) }
)

;; Admin principal
(define-data-var contract-admin principal tx-sender)

;; Functions to manage contract admin
(define-read-only (get-contract-admin)
  (ok (var-get contract-admin))
)

(define-public (set-contract-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    (ok (var-set contract-admin new-admin))
  )
)

;; Helper function to check if caller is the owner of a dataset
(define-private (is-dataset-owner (dataset-id uint))
  (let (
    (dataset-owner (get owner (default-to { owner: tx-sender } (map-get? datasets { dataset-id: dataset-id }))))
  )
    (is-eq tx-sender dataset-owner)
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
    
    ;; Add to owner's dataset list
    (let (
      (current-datasets (default-to { dataset-ids: (list) } (map-get? datasets-by-owner { owner: owner-principal })))
      (updated-dataset-ids (unwrap-panic (as-max-len? (append (get dataset-ids current-datasets) dataset-id) u1000)))
    )
      (map-set datasets-by-owner
        { owner: owner-principal }
        { dataset-ids: updated-dataset-ids }
      )
    )
    
    ;; Increment counter
    (var-set dataset-counter dataset-id)
    
    ;; Return the dataset ID
    (ok dataset-id)
  )
)

;; Update dataset metadata
(define-public (update-dataset-metadata
  (dataset-id uint)
  (name (string-utf8 100))
  (description (string-utf8 500))
  (data-type (string-utf8 50))
  (is-public bool))
  
  (let (
    (dataset (unwrap! (map-get? datasets { dataset-id: dataset-id }) ERR-DATASET-NOT-FOUND))
  )
    ;; Check if caller is the owner
    (asserts! (is-dataset-owner dataset-id) ERR-NOT-AUTHORIZED)
    
    ;; Check if metadata is not frozen
    (asserts! (not (get metadata-frozen dataset)) ERR-METADATA-FROZEN)
    
    ;; Update the dataset
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

;; Freeze dataset metadata
(define-public (freeze-dataset-metadata (dataset-id uint))
  (let (
    (dataset (unwrap! (map-get? datasets { dataset-id: dataset-id }) ERR-DATASET-NOT-FOUND))
  )
    ;; Check if caller is the owner
    (asserts! (is-dataset-owner dataset-id) ERR-NOT-AUTHORIZED)
    
    ;; Update the dataset
    (map-set datasets 
      { dataset-id: dataset-id }
      (merge dataset {
        metadata-frozen: true
      })
    )
    
    (ok true)
  )
)

;; Transfer dataset ownership
(define-public (transfer-dataset (dataset-id uint) (new-owner principal))
  (let (
    (dataset (unwrap! (map-get? datasets { dataset-id: dataset-id }) ERR-DATASET-NOT-FOUND))
    (current-owner tx-sender)
  )
    ;; Check if caller is the owner
    (asserts! (is-dataset-owner dataset-id) ERR-NOT-AUTHORIZED)
    
    ;; Get current datasets for both owners
    (let (
      (current-owner-datasets (default-to { dataset-ids: (list) } (map-get? datasets-by-owner { owner: current-owner })))
      (new-owner-datasets (default-to { dataset-ids: (list) } (map-get? datasets-by-owner { owner: new-owner })))
      (current-owner-updated-ids (filter (lambda (id) (not (is-eq id dataset-id))) (get dataset-ids current-owner-datasets)))
      (new-owner-updated-ids (unwrap-panic (as-max-len? (append (get dataset-ids new-owner-datasets) dataset-id) u1000)))
    )
      ;; Update the dataset ownership
      (map-set datasets 
        { dataset-id: dataset-id }
        (merge dataset {
          owner: new-owner
        })
      )
      
      ;; Update the owner maps
      (map-set datasets-by-owner
        { owner: current-owner }
        { dataset-ids: current-owner-updated-ids }
      )
      
      (map-set datasets-by-owner
        { owner: new-owner }
        { dataset-ids: new-owner-updated-ids }
      )
      
      (ok true)
    )
  )
)

;; Read-only functions

;; Get dataset information
(define-read-only (get-dataset (dataset-id uint))
  (let (
    (dataset (map-get? datasets { dataset-id: dataset-id }))
  )
    (match dataset
      data (ok data)
      (err ERR-DATASET-NOT-FOUND)
    )
  )
)

;; Get all datasets by owner
(define-read-only (get-datasets-by-owner (owner principal))
  (let (
    (owner-data (map-get? datasets-by-owner { owner: owner }))
  )
    (match owner-data
      data (ok (get dataset-ids data))
      (ok (list))
    )
  )
)

;; Get total number of datasets
(define-read-only (get-dataset-count)
  (ok (var-get dataset-counter))
)

;; Check if a dataset is public
(define-read-only (is-dataset-public (dataset-id uint))
  (let (
    (dataset (map-get? datasets { dataset-id: dataset-id }))
  )
    (match dataset
      data (ok (get is-public data))
      (err ERR-DATASET-NOT-FOUND)
    )
  )
)
