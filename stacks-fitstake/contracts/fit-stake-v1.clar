;; FitStake - Core + Group Challenges

;; Constants
(define-constant contract-owner tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-STAKE (err u101))
(define-constant ERR-NO-ACTIVE-STAKE (err u102))
(define-constant ERR-CHALLENGE-NOT-FOUND (err u103))
(define-constant ERR-ALREADY-IN-CHALLENGE (err u104))
(define-constant ERR-INVALID-WORKOUT (err u105))
(define-constant ERR-INVALID-DURATION (err u106))
(define-constant ERR-INVALID-MIN-PARTICIPANTS (err u107))
(define-constant ERR-INVALID-STAKE-REQUIREMENT (err u108))
(define-constant ERR-INVALID-CHALLENGE-NAME (err u109))

;; Data Variables
(define-data-var minimum-stake uint u100000000) ;; 100 STX
(define-data-var challenge-counter uint u0)

;; Data Maps
(define-map user-stakes 
    { user: principal } 
    { 
        amount: uint,
        start-time: uint,
        end-time: uint,
        weekly-target: uint,
        workouts-this-week: uint
    }
)

(define-map workouts
    { user: principal, id: uint } 
    {
        activity-type: (string-utf8 20),
        duration: uint,
        intensity: uint
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

;; Read-Only Functions
(define-read-only (get-user-stake (user principal))
    (map-get? user-stakes {user: user}))

(define-read-only (get-challenge (challenge-id uint))
    (map-get? group-challenges {challenge-id: challenge-id}))

(define-read-only (get-challenge-participation (challenge-id uint) (user principal))
    (map-get? challenge-participants {challenge-id: challenge-id, user: user}))

;; Private Functions
(define-private (is-valid-workout (workout { duration: uint, intensity: uint }))
    (and 
        (> (get duration workout) u0)
        (and (>= (get intensity workout) u1) (<= (get intensity workout) u5))))

(define-private (is-valid-challenge-params (params { name: (string-utf8 50), duration: uint, stake-requirement: uint, min-participants: uint }))
    (begin
        (asserts! (> (len (get name params)) u0) ERR-INVALID-CHALLENGE-NAME)
        (asserts! (> (get duration params) u0) ERR-INVALID-DURATION)
        (asserts! (>= (get stake-requirement params) (var-get minimum-stake)) ERR-INVALID-STAKE-REQUIREMENT)
        (asserts! (> (get min-participants params) u0) ERR-INVALID-MIN-PARTICIPANTS)
        (ok true)))

(define-private (is-active-stake (user principal))
    (match (get-user-stake user)
        stake (< block-height (get end-time stake))
        false))

(define-private (update-challenge-progress (user principal))
    (match (get-user-stake user)
        stake (map-set user-stakes {user: user}
            (merge stake { workouts-this-week: (+ (get workouts-this-week stake) u1) }))
        false))

;; Public Functions
(define-public (stake-tokens (amount uint) (weekly-target uint))
    (let ((caller tx-sender))
        (asserts! (>= amount (var-get minimum-stake)) ERR-INVALID-STAKE)
        (asserts! (> weekly-target u0) ERR-INVALID-STAKE)
        
        (try! (stx-transfer? amount caller (as-contract tx-sender)))
        
        (map-set user-stakes {user: caller}
            {
                amount: amount,
                start-time: block-height,
                end-time: (+ block-height u1440),
                weekly-target: weekly-target,
                workouts-this-week: u0
            }
        )
        (ok true)))

(define-public (record-workout (workout { activity-type: (string-utf8 20), duration: uint, intensity: uint }))
    (let 
        ((caller tx-sender)
         (validated-workout {
             activity-type: (get activity-type workout),
             duration: (get duration workout),
             intensity: (get intensity workout)
         }))
        (asserts! (is-active-stake caller) ERR-NO-ACTIVE-STAKE)
        (asserts! (is-valid-workout { duration: (get duration workout), intensity: (get intensity workout) }) ERR-INVALID-WORKOUT)
        (asserts! (> (len (get activity-type workout)) u0) ERR-INVALID-WORKOUT)
        
        (map-set workouts 
            {user: caller, id: block-height}
            validated-workout)
        (update-challenge-progress caller)
        (ok true)))

(define-public (create-group-challenge (params { name: (string-utf8 50), duration: uint, stake-requirement: uint, min-participants: uint }))
    (let 
        ((caller tx-sender)
         (challenge-id (+ (var-get challenge-counter) u1))
         (validated-params {
             name: (get name params),
             duration: (get duration params),
             stake-requirement: (get stake-requirement params),
             min-participants: (get min-participants params)
         }))
        
        (asserts! (is-eq caller contract-owner) ERR-NOT-AUTHORIZED)
        (try! (is-valid-challenge-params params))
        
        (map-set group-challenges { challenge-id: challenge-id }
            {
                name: (get name validated-params),
                start-time: block-height,
                end-time: (+ block-height (get duration validated-params)),
                stake-requirement: (get stake-requirement validated-params),
                min-participants: (get min-participants validated-params),
                active: true
            })
            
        (var-set challenge-counter challenge-id)
        (ok challenge-id)))

(define-public (join-challenge (challenge-id uint))
    (let 
        ((caller tx-sender))
        (match (get-user-stake caller)
            stake 
            (match (get-challenge challenge-id)
                challenge (begin
                    (asserts! (get active challenge) ERR-CHALLENGE-NOT-FOUND)
                    (asserts! (>= (get amount stake) (get stake-requirement challenge)) ERR-INVALID-STAKE)
                    (asserts! (is-none (get-challenge-participation challenge-id caller)) ERR-ALREADY-IN-CHALLENGE)
                    
                    (map-set challenge-participants 
                        {challenge-id: challenge-id, user: caller}
                        {
                            joined-at: block-height,
                            workouts-completed: u0,
                            eligible-for-reward: true
                        })
                    (ok true))
                ERR-CHALLENGE-NOT-FOUND)
            ERR-NO-ACTIVE-STAKE)))

;; Initialize Contract
(begin 
    (var-set challenge-counter u0))