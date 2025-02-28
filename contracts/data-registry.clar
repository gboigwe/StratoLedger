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
      none false
    )
  )
)
