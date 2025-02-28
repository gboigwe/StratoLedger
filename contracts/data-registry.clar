;; StratoSense Data Registry - v2
;; Clarity 2.8.0 Implementation
;; This contract manages the registration and maintenance of atmospheric data records

;; Constants for error handling
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-NOT-FOUND (err u404))
(define-constant ERR-INVALID-PARAMS (err u400))
(define-constant ERR-FROZEN (err u403))
(define-constant ERR-LIMIT-REACHED (err u429))

;; Constants for validation
(define-constant MAX-ALTITUDE u100000) ;; Maximum altitude in meters
(define-constant MAX-DATASETS-PER-USER u1000)
(define-constant VALIDATOR-THRESHOLD u3) ;; Minimum validators needed

;; Principal Variables
(define-data-var contract-owner principal tx-sender)

;; Data structures
(define-map datasets
    {id: uint}
    {
        owner: principal,
        name: (string-ascii 64),
        description: (string-utf8 256),
        altitude: uint,
        coordinates: {lat: int, lng: int},
        ipfs-hash: (buff 32),
        timestamp: uint,
        status: (string-ascii 12), ;; pending, active, verified
        validator-count: uint,
        is-frozen: bool
    }
)

;; Track dataset IDs by owner
(define-map owner-datasets 
    {owner: principal} 
    {dataset-ids: (list 1000 uint)}
)

;; Track dataset validations
(define-map dataset-validations
    {dataset-id: uint, validator: principal}
    {validated: bool, timestamp: uint}
)

;; Counter for dataset IDs
(define-data-var next-id uint u1)

;; Getters
(define-read-only (get-dataset (id uint))
    (map-get? datasets {id: id})
)

(define-read-only (get-owner-datasets (owner principal))
    (default-to {dataset-ids: (list)} 
        (map-get? owner-datasets {owner: owner}))
)

(define-read-only (get-dataset-validation (dataset-id uint) (validator principal))
    (map-get? dataset-validations {dataset-id: dataset-id, validator: validator})
)

;; Private functions
(define-private (is-valid-coordinates (lat int) (lng int))
    (and 
        (and (>= lat (* -90 1000000)) (<= lat (* 90 1000000)))
        (and (>= lng (* -180 1000000)) (<= lng (* 180 1000000)))
    )
)

(define-private (can-modify-dataset (id uint))
    (match (map-get? datasets {id: id})
        dataset (and 
            (is-eq (get owner dataset) tx-sender)
            (not (get is-frozen dataset))
        )
        false
    )
)

(define-private (update-owner-datasets (owner principal) (dataset-id uint))
    (let (
        (current-data (get-owner-datasets owner))
        (current-ids (get dataset-ids current-data))
        (current-len (len current-ids))
    )
        (asserts! (< current-len u1000) ERR-LIMIT-REACHED)
        (ok (map-set owner-datasets
            {owner: owner}
            {dataset-ids: (unwrap! (as-max-len? (append current-ids dataset-id) u1000)
                                 ERR-LIMIT-REACHED)}
        ))
    )
)

;; Public functions
(define-public (register-dataset 
        (name (string-ascii 64))
        (description (string-utf8 256))
        (altitude uint)
        (lat int)
        (lng int)
        (ipfs-hash (buff 32)))
    (let (
        (dataset-id (var-get next-id))
    )
        (asserts! (<= altitude MAX-ALTITUDE) ERR-INVALID-PARAMS)
        (asserts! (is-valid-coordinates lat lng) ERR-INVALID-PARAMS)
        
        (try! (update-owner-datasets tx-sender dataset-id))
        
        (map-set datasets
            {id: dataset-id}
            {
                owner: tx-sender,
                name: name,
                description: description,
                altitude: altitude,
                coordinates: {lat: lat, lng: lng},
                ipfs-hash: ipfs-hash,
                timestamp: block-height,
                status: "pending",
                validator-count: u0,
                is-frozen: false
            }
        )
        
        (var-set next-id (+ dataset-id u1))
        (ok dataset-id)
    )
)

(define-public (validate-dataset (dataset-id uint))
    (let (
        (dataset (unwrap! (get-dataset dataset-id) ERR-NOT-FOUND))
        (current-validation (get-dataset-validation dataset-id tx-sender))
    )
        ;; Ensure validator hasn't already validated
        (asserts! (is-none current-validation) ERR-NOT-AUTHORIZED)
        
        ;; Record validation
        (map-set dataset-validations 
            {dataset-id: dataset-id, validator: tx-sender}
            {validated: true, timestamp: block-height}
        )
        
        ;; Update validator count
        (let ((new-count (+ (get validator-count dataset) u1)))
            (map-set datasets
                {id: dataset-id}
                (merge dataset {
                    validator-count: new-count,
                    status: (if (>= new-count VALIDATOR-THRESHOLD) 
                              "verified" 
                              (get status dataset))
                })
            )
        )
        (ok true)
    )
)

(define-public (update-dataset
        (dataset-id uint)
        (name (string-ascii 64))
        (description (string-utf8 256)))
    (let ((dataset (unwrap! (get-dataset dataset-id) ERR-NOT-FOUND)))
        (asserts! (can-modify-dataset dataset-id) ERR-NOT-AUTHORIZED)
        (ok (map-set datasets
            {id: dataset-id}
            (merge dataset {
                name: name,
                description: description
            })
        ))
    )
)

(define-public (freeze-dataset (dataset-id uint))
    (let ((dataset (unwrap! (get-dataset dataset-id) ERR-NOT-FOUND)))
        (asserts! (is-eq (get owner dataset) tx-sender) ERR-NOT-AUTHORIZED)
        (ok (map-set datasets
            {id: dataset-id}
            (merge dataset {
                is-frozen: true
            })
        ))
    )
)

(define-public (transfer-ownership (dataset-id uint) (new-owner principal))
    (let ((dataset (unwrap! (get-dataset dataset-id) ERR-NOT-FOUND)))
        (asserts! (is-eq (get owner dataset) tx-sender) ERR-NOT-AUTHORIZED)
        
        ;; Remove from current owner's list
        (let ((current-owner-data (get-owner-datasets tx-sender)))
            (map-set owner-datasets
                {owner: tx-sender}
                {dataset-ids: (filter not-equal-to-id 
                    (get dataset-ids current-owner-data))}
            )
        )
        
        ;; Add to new owner's list
        (try! (update-owner-datasets new-owner dataset-id))
        
        ;; Update dataset owner
        (ok (map-set datasets
            {id: dataset-id}
            (merge dataset {
                owner: new-owner
            })
        ))
    )
)

;; Helper for transfer-ownership
(define-private (not-equal-to-id (id uint)) 
    (not (is-eq id id))
)
