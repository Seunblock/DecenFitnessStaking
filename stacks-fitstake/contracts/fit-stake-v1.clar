;; FitStake - Fitness Staking and Rewards Contract

;; Constants
(define-constant contract-owner tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-STAKE (err u101))
(define-constant ERR-NO-ACTIVE-STAKE (err u102))
(define-constant ERR-CHALLENGE-NOT-FOUND (err u103))
(define-constant ERR-ALREADY-IN-CHALLENGE (err u104))
(define-constant ERR-INVALID-WORKOUT (err u105))

;; Data Variables
(define-data-var minimum-stake uint u100000000) ;; 100 STX
(define-data-var total-pool-balance uint u0)
(define-data-var challenge-counter uint u0)

;; Data Maps
(define-map user-stakes 
    { user: principal } 
    { 
        amount: uint,
        start-time: uint,
        end-time: uint,
        goals-met: uint,
        weekly-target: uint,
        workouts-this-week: uint,
        last-workout: uint
    }
)

(define-map group-challenges
    { challenge-id: uint }
    {
        name: (string-utf8 50),
        start-time: uint,
        end-time: uint,
        stake-requirement: uint,
        min-participants: uint,
        reward-pool: uint,
        active: bool
    }
)

(define-map challenge-participants
    { challenge-id: uint, user: principal }
    {
        joined-at: uint,
        workouts-completed: uint,
        eligible-for-reward: bool
    }
)

(define-map fitness-data 
    { user: principal, timestamp: uint } 
    { 
        activity-type: (string-utf8 20),
        duration: uint,
        intensity: uint,
        verified: bool
    }
)

;; Read-Only Functions
(define-read-only (get-user-stake (user principal))
    (map-get? user-stakes {user: user}))

(define-read-only (get-challenge (challenge-id uint))
    (map-get? group-challenges {challenge-id: challenge-id}))

(define-read-only (get-challenge-participation (challenge-id uint) (user principal))
    (map-get? challenge-participants {challenge-id: challenge-id, user: user}))

;; Public Functions
(define-public (stake-tokens (amount uint) (weekly-target uint))
    (let ((caller tx-sender))
        (asserts! (>= amount (var-get minimum-stake)) ERR-INVALID-STAKE)
        (asserts! (> weekly-target u0) ERR-INVALID-STAKE)
        
        (try! (stx-transfer? amount caller (as-contract tx-sender)))
        (var-set total-pool-balance (+ (var-get total-pool-balance) amount))
        
        (map-set user-stakes {user: caller}
            {
                amount: amount,
                start-time: block-height,
                end-time: (+ block-height u1440), ;; 30 days in blocks
                goals-met: u0,
                weekly-target: weekly-target,
                workouts-this-week: u0,
                last-workout: u0
            }
        )
        (ok true)))

(define-public (submit-workout (activity-type (string-utf8 20)) (duration uint) (intensity uint))
    (let (
        (caller tx-sender)
        (current-block block-height)
        )
        (asserts! (is-valid-workout duration intensity) (err ERR-INVALID-WORKOUT))
        (asserts! (is-active-stake caller) (err ERR-NO-ACTIVE-STAKE))
        
        (try! (record-workout caller current-block activity-type duration intensity))
        (try! (update-challenge-progress caller))
        (try! (check-weekly-goal caller))
        
        (ok true)))

(define-public (create-group-challenge (name (string-utf8 50)) (duration uint) (stake-requirement uint) (min-participants uint))
    (let (
        (caller tx-sender)
        (challenge-id (+ (var-get challenge-counter) u1))
        )
        (asserts! (is-eq caller contract-owner) ERR-NOT-AUTHORIZED)
        
        (map-set group-challenges {challenge-id: challenge-id}
            {
                name: name,
                start-time: block-height,
                end-time: (+ block-height duration),
                stake-requirement: stake-requirement,
                min-participants: min-participants,
                reward-pool: u0,
                active: true
            }
        )
        (var-set challenge-counter challenge-id)
        (ok challenge-id)))

(define-public (join-challenge (challenge-id uint))
    (let (
        (caller tx-sender)
        (stake (unwrap! (get-user-stake caller) ERR-NO-ACTIVE-STAKE))
        (challenge (unwrap! (get-challenge challenge-id) ERR-CHALLENGE-NOT-FOUND))
        )
        (asserts! (get active challenge) ERR-CHALLENGE-NOT-FOUND)
        (asserts! (>= (get amount stake) (get stake-requirement challenge)) ERR-INVALID-STAKE)
        (asserts! (is-none (get-challenge-participation challenge-id caller)) ERR-ALREADY-IN-CHALLENGE)
        
        (map-set challenge-participants {challenge-id: challenge-id, user: caller}
            {
                joined-at: block-height,
                workouts-completed: u0,
                eligible-for-reward: true
            }
        )
        (ok true)))

;; Private Functions
(define-private (is-valid-workout (duration uint) (intensity uint))
    (and 
        (> duration u0)
        (and (>= intensity u1) (<= intensity u5))))

(define-private (is-active-stake (user principal))
    (match (get-user-stake user)
        stake (< block-height (get end-time stake))
        false))

(define-private (record-workout (user principal) (timestamp uint) (activity-type (string-utf8 20)) (duration uint) (intensity uint))
    (map-set fitness-data 
        {user: user, timestamp: timestamp}
        {
            activity-type: activity-type,
            duration: duration,
            intensity: intensity,
            verified: true
        }
    )
    (ok true))

(define-private (update-challenge-progress (user principal))
    (match (get-user-stake user)
        stake 
        (begin
            (map-set user-stakes {user: user}
                (merge stake {
                    workouts-this-week: (+ (get workouts-this-week stake) u1),
                    last-workout: block-height
                }))
            (ok true))
        ERR-NO-ACTIVE-STAKE))

(define-private (check-weekly-goal (user principal))
    (match (get-user-stake user)
        stake 
        (if (>= (get workouts-this-week stake) (get weekly-target stake))
            (distribute-reward user (get amount stake))
            (ok true))
        ERR-NO-ACTIVE-STAKE))

(define-private (distribute-reward (user principal) (stake-amount uint))
    (let ((reward (/ (* stake-amount u5) u100))) ;; 5% reward
        (try! (as-contract (stx-transfer? reward tx-sender user)))
        (var-set total-pool-balance (- (var-get total-pool-balance) reward))
        (ok true)))

;; Initialize Contract
(begin 
    (var-set challenge-counter u0)
    (var-set total-pool-balance u0))