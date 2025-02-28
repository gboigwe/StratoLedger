;; StratoSense Data Registry
;; Version: 3.0
;; Implements atmospheric data management with improved structure and error handling

;; Constants and Error Codes
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-NOT-FOUND (err u404))
(define-constant ERR-INVALID-PARAMS (err u400))
(define-constant ERR-METADATA-FROZEN (err u403))
(define-constant ERR-LIST-FULL (err u429))

;; Data Validation Constants
(define-constant MAX-LAT-MULTIPLIER (* 90 1000000))
(define-constant MAX-LON-MULTIPLIER (* 180 1000000))
(define-constant MAX-LIST-SIZE u1000)

;; Data Structures
(define-map datasets
    { dataset-id: uint }
    {
        owner: principal,
        metadata: {
            name: (string-utf8 100),
            description: (string-utf8 500),
            data-type: (string-utf8 50)
        },
        location: {
            altitude-min: uint,
            altitude-max: uint,
            latitude: int,
            longitude: int
        },
        storage: {
            ipfs-hash: (string-ascii 100),
            created-at: uint
        },
        flags: {
            is-public: bool,
            metadata-frozen: bool
        }
    }
)

;; Owner dataset tracking
(define-map datasets-by-owner
    { owner: principal }
    { dataset-ids: (list 1000 uint) }
)

;; State Variables
(define-data-var dataset-counter uint u0)

;; Private Helper Functions

;; Validates geographic coordinates
(define-private (validate-coordinates (lat int) (lon int))
    (and 
        (and (>= lat (- MAX-LAT-MULTIPLIER)) (<= lat MAX-LAT-MULTIPLIER))
        (and (>= lon (- MAX-LON-MULTIPLIER)) (<= lon MAX-LON-MULTIPLIER))
    )
)

;; Validates altitude range
(define-private (validate-altitude-range (min uint) (max uint))
    (and 
        (>= min u0)
        (>= max min)
    )
)

;; Updates owner's dataset list safely
(define-private (update-owner-dataset-list (owner principal) (dataset-id uint) (is-add bool))
    (let (
        (current-data (default-to { dataset-ids: (list) } 
                      (map-get? datasets-by-owner { owner: owner })))
        (current-ids (get dataset-ids current-data))
    )
        (if is-add
            ;; Adding dataset
            (if (>= (len current-ids) u1000)
                ERR-LIST-FULL
                (ok (map-set datasets-by-owner
                    { owner: owner }
                    { dataset-ids: (unwrap! (as-max-len? 
                        (append current-ids dataset-id) u1000)
                        ERR-LIST-FULL) }
                )))
            ;; Removing dataset
            (ok (map-set datasets-by-owner
                { owner: owner }
                { dataset-ids: (filter remove-dataset-id current-ids) }
            ))
        )
    )
)

;; Helper for filtering dataset IDs
(define-private (remove-dataset-id (id uint)) 
    (not (is-eq id id))
)

;; Verifies dataset ownership
(define-private (is-dataset-owner (dataset-id uint))
    (match (map-get? datasets { dataset-id: dataset-id })
        data (is-eq tx-sender (get owner data))
        false
    )
)

;; Public Functions

;; Registers a new atmospheric dataset
(define-public (register-dataset 
        (name (string-utf8 100))
        (description (string-utf8 500))
        (data-type (string-utf8 50))
        (altitude-min uint)
        (altitude-max uint)
        (latitude int)
        (longitude int)
        (ipfs-hash (string-ascii 100))
        (is-public bool))
    (let (
        (dataset-id (+ (var-get dataset-counter) u1))
        (current-time (unwrap-panic (get-block-info? time u0)))
    )
        ;; Input validation
        (asserts! (validate-altitude-range altitude-min altitude-max) ERR-INVALID-PARAMS)
        (asserts! (validate-coordinates latitude longitude) ERR-INVALID-PARAMS)
        
        ;; Create dataset
        (map-set datasets
            { dataset-id: dataset-id }
            {
                owner: tx-sender,
                metadata: {
                    name: name,
                    description: description,
                    data-type: data-type
                },
                location: {
                    altitude-min: altitude-min,
                    altitude-max: altitude-max,
                    latitude: latitude,
                    longitude: longitude
                },
                storage: {
                    ipfs-hash: ipfs-hash,
                    created-at: current-time
                },
                flags: {
                    is-public: is-public,
                    metadata-frozen: false
                }
            }
        )
        
        ;; Update owner's dataset list
        (try! (update-owner-dataset-list tx-sender dataset-id true))
        
        ;; Update counter and return
        (var-set dataset-counter dataset-id)
        (ok dataset-id)
    )
)

;; Updates dataset metadata
(define-public (update-dataset-metadata
        (dataset-id uint)
        (name (string-utf8 100))
        (description (string-utf8 500))
        (data-type (string-utf8 50))
        (is-public bool))
    (let ((dataset (unwrap! (map-get? datasets { dataset-id: dataset-id }) ERR-NOT-FOUND)))
        (asserts! (is-dataset-owner dataset-id) ERR-NOT-AUTHORIZED)
        (asserts! (not (get metadata-frozen (get flags dataset))) ERR-METADATA-FROZEN)
        
        (map-set datasets
            { dataset-id: dataset-id }
            (merge dataset {
                metadata: {
                    name: name,
                    description: description,
                    data-type: data-type
                },
                flags: (merge (get flags dataset) {
                    is-public: is-public
                })
            })
        )
        (ok true)
    )
)

;; Freezes dataset metadata
(define-public (freeze-dataset-metadata (dataset-id uint))
    (let ((dataset (unwrap! (map-get? datasets { dataset-id: dataset-id }) ERR-NOT-FOUND)))
        (asserts! (is-dataset-owner dataset-id) ERR-NOT-AUTHORIZED)
        
        (ok (map-set datasets
            { dataset-id: dataset-id }
            (merge dataset {
                flags: (merge (get flags dataset) {
                    metadata-frozen: true
                })
            })
        ))
    )
)

;; Transfers dataset ownership
(define-public (transfer-dataset (dataset-id uint) (new-owner principal))
    (let ((dataset (unwrap! (map-get? datasets { dataset-id: dataset-id }) ERR-NOT-FOUND)))
        ;; Verify ownership
        (asserts! (is-dataset-owner dataset-id) ERR-NOT-AUTHORIZED)
        
        ;; Remove from current owner's list
        (try! (update-owner-dataset-list tx-sender dataset-id false))
        
        ;; Add to new owner's list
        (try! (update-owner-dataset-list new-owner dataset-id true))
        
        ;; Update dataset ownership
        (map-set datasets
            { dataset-id: dataset-id }
            (merge dataset { owner: new-owner })
        )
        (ok true)
    )
)

;; Read-Only Functions

;; Gets dataset information
(define-read-only (get-dataset (dataset-id uint))
    (map-get? datasets { dataset-id: dataset-id })
)

;; Gets all datasets owned by a principal
(define-read-only (get-datasets-by-owner (owner principal))
    (default-to { dataset-ids: (list) }
        (map-get? datasets-by-owner { owner: owner }))
)

;; Gets total number of registered datasets
(define-read-only (get-dataset-count)
    (ok (var-get dataset-counter))
)

;; Checks if a dataset is public
(define-read-only (is-dataset-public (dataset-id uint))
    (match (map-get? datasets { dataset-id: dataset-id })
        data (ok (get is-public (get flags data)))
        (err ERR-NOT-FOUND)
    )
)
