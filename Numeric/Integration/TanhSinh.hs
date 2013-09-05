{-# LANGUAGE BangPatterns, PatternGuards #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Numeric.Integration.TanhSinh
-- Copyright   :  (C) 2012 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  provisional
-- Portability :  portable
--
-- An implementation of Takahashi and Mori's Tanh-Sinh
-- quadrature.
--
-- <http://en.wikipedia.org/wiki/Tanh-sinh_quadrature>
--
-- Tanh-Sinh provides good results across a wide-range
-- of functions and is pretty much as close to a
-- universal quadrature scheme as is possible. It is also
-- robust against error in the presence of singularities at
-- the endpoints of the integral.
--
-- The change of basis is precomputed, and information is
-- gained quadratically in the number of digits.
--
-- > ghci> absolute 1e-6 $ parTrap sin (pi/2) pi
-- > Result {result = 0.9999999999999312, errorEstimate = 2.721789573237518e-10, evaluations = 25}
--
-- > ghci> confidence $ absolute 1e-6 $ trap sin (pi/2) pi
-- > (0.9999999997277522,1.0000000002721101)
--
-- Unlike most quadrature schemes, this method is also fairly robust against
-- singularities at the end points.
--
-- > ghci> absolute 1e-6 $ trap (recip . sqrt . sin) 0 1
-- > Result {result = 2.03480500404275, errorEstimate = 6.349514558579017e-8, evaluations = 49}
--
-- See <http://www.johndcook.com/blog/2012/02/21/care-and-treatment-of-singularities/>
-- for a sense of how more naive quadrature schemes fare.
----------------------------------------------------------------------------
module Numeric.Integration.TanhSinh
  (
  -- * Quadrature methods
    trap -- Trapezoid rule for Tanh-Sinh quadrature
  , simpson -- Simpson's rule for Tanh-Sinh quadrature
  , trap'
  , simpson'
  , parTrap
  , parSimpson
  , Result(..)
  -- * Estimated error bounds
  , absolute -- absolute error
  , relative -- relative error
  -- * Confidence intervals
  , confidence
  -- * Changes of variables
  , nonNegative
  , everywhere
  ) where

import Control.Parallel.Strategies
import Data.List (foldl')

-- | Integral with an result and an estimate of the error such that
-- @(result - errorEstimate, result + errorEstimate)@ /probably/ bounds 
-- the actual answer.
data Result = Result
  { result        :: {-# UNPACK #-} !Double
  , errorEstimate :: {-# UNPACK #-} !Double
  , evaluations   :: {-# UNPACK #-} !Int
  } deriving (Read,Show,Eq,Ord)

-- | Convert a Result to a confidence interval
confidence :: Result -> (Double, Double)
confidence (Result a b _) = (a - b, a + b)

-- | Filter a list of results using a specified absolute error bound
absolute :: Double -> [Result] -> Result
absolute targetError = go where
  go [] = error "no result"
  go [r] = r
  go (r@(Result _ e _):rs)
    | e < targetError*0.1 = r
    | otherwise = absolute targetError rs

-- | Filter a list of results using a specified relative error bound
relative :: Double -> [Result] -> Result
relative _ [] = error "no result"
relative _ [r] = r
relative targetError (r'@(Result a _ _):rs') = go a r' rs' where
  go olds _ (r@(Result s e _):rs)
    | abs (s - olds) < targetError * e || s == 0 && olds == 0 = r
    | otherwise                                               = go s r rs
  go _ oldr [] = oldr

m_huge :: Double
m_huge = 1/0 -- 1.7976931348623157e308

-- | Integrate a function from 0 to infinity by using the change of variables @x = t/(1-t)@
--
-- This works /much/ better than just clipping the interval at some arbitrary large number.
nonNegative :: ((Double -> Double) -> Double -> Double -> r) -> (Double -> Double) -> r
nonNegative method f = method (\t -> f(t/(1-t))/square(1-t)) 0 1 where
  square x = x * x

-- | Integrate from -inf to inf using tanh-sinh quadrature after using the change of variables @x = tan t@
--
-- > everywhere trap (\x -> exp(-x*x))
--
-- This works /much/ better than just clipping the interval at arbitrary large and small numbers.

-- TODO: build a custom set of change of variable tables
everywhere :: ((Double -> Double) -> Double -> Double -> r) -> (Double -> Double) -> r
everywhere method f = method (\t -> let tant = tan t in f tant * (1 + tant * tant)) (-pi/2) (pi/2)

-- | Integration using a truncated trapezoid rule and tanh-sinh quadrature with a specified evaluation strategy
trap' :: Strategy [Double] -> (Double -> Double) -> Double -> Double -> [Result]
trap' nf f a b = go (0 :: Int) (i0+i1) (abs (i1-i0)) m_huge dd where
  go !k !t !old_delta !err (ds:dds) = res t' err' k : go (k+1) t' delta err' dds
    where
      !ht' = tr ds
      !ht = 0.5*t
      !t' = ht'+ht
      !delta = abs (ht'-ht)
      !err' | delta == 0 || old_delta == 0                         = err
            | r <- log delta / log old_delta, 1.99 < r && r < 2.01 = delta*delta
            | otherwise                                            = delta
  go !k !t !_ !err [] = [res t err k]
  res i e k = Result (i*c) (e*c) (1 + 12*(2^k))
  c  = 0.5 * (b - a)
  d  = 0.5 * (a + b)
  i0 = w0 * f d + tr dd0
  i1 = tr dd1
  tr xs = foldl' (+) 0 (map (\(DD i w) -> let !ci = c * i in w*(f(d+ci)+f(d-ci))) xs `using` nf)

-- | Integration using a truncated trapezoid rule under tanh-sinh quadrature
trap :: (Double -> Double) -> Double -> Double -> [Result]
trap = trap' r0

-- | Integration using a truncated trapezoid rule under tanh-sinh quadrature with buffered parallel evaluation
parTrap :: (Double -> Double) -> Double -> Double -> [Result]
parTrap = trap' (parBuffer 32 rseq)

-- | Integration using a truncated Simpson's rule under tanh-sinh quadrature with a specified evaluation strategy
simpson' :: Strategy [Double] -> (Double -> Double) -> Double -> Double -> [Result]
simpson' nf f a b = go (0 :: Int) i01 (i01*4/3) (abs (i1-i0)) m_huge dd where
  go !k !t !s !old_delta !err (ds:dds) = res s' err' k : go (k+1) t' s' delta err' dds
    where
      !ht' = tr ds
      !ht = 0.5*t
      !t' = ht'+ht
      !s' = (4*t'-t)/3
      !delta = abs (s'-s)
      !err' | delta == 0 || old_delta == 0                         = err
            | r <- log delta / log old_delta, 1.99 < r && r < 2.01 = delta*delta
            | otherwise                                            = delta
  go !k _ !s !_ !err [] = [res s err k]
  res i e k = Result (i*c) (e*c) (1 + 12*(2^k))
  c  = 0.5 * (b - a)
  d  = 0.5 * (a + b)
  i0 = w0 * f d + tr dd0
  i1 = tr dd1
  i01 = i0 + i1
  tr xs = foldl' (+) 0 (map (\(DD i w) -> let !ci = c * i in w*(f(d+ci)+f(d-ci))) xs `using` nf)

-- | Integration using a truncated Simpson's rule under tanh-sinh quadrature
simpson :: (Double -> Double) -> Double -> Double -> [Result]
simpson = simpson' r0

-- | Integration using a truncated Simpson's rule under tanh-sinh quadrature with buffered parallel evaluation
parSimpson  :: (Double -> Double) -> Double -> Double -> [Result]
parSimpson = simpson' (parBuffer 32 rseq)

data DD = DD {-# UNPACK #-} !Double {-# UNPACK #-} !Double
  deriving Show

w0 :: Double
w0 = 0.7853981633974483

dd0, dd1 :: [DD]
dd0 = [DD 0.9513679640727469 0.11501119725739434,DD 0.9999774771924616 1.3310025687635846e-4,DD 0.999999999999957 3.395446068634773e-13]
dd1 = [DD 0.6742714922484359 0.4829882897061506,DD 0.9975148564572244 9.171583494963921e-3,DD 0.9999999888756649 1.071560227847152e-7]

dd :: [[DD]]
dd = [
 [DD 0.3772097381640342 0.3474036898118141,
  DD 0.8595690586898966 0.1327695688570135,
  DD 0.9870405605073769 1.9096435892708076e-2,
  DD 0.9996882640283532 7.256294369753284e-4,
  DD 0.9999992047371147 2.99592534079268e-6,
  DD 0.9999999999528565 2.9077914535639456e-10],

 [DD 0.19435700332493544 0.19041046482933816,
  DD 0.5391467053879677 0.14918287823114462,
  DD 0.7806074389832003 9.217973104519347e-2,
  DD 0.9148792632645746 4.505767730866796e-2,
  DD 0.9739668681956775 1.7177763466645967e-2,
  DD 0.9940555066314022 4.896875686700097e-3,
  DD 0.9990651964557858 9.678251282580301e-4,
  DD 0.999909384695144 1.1874335053543359e-4,
  DD 0.9999953160412205 7.810319905093011e-6,
  DD 0.9999998927816124 2.2829150742138325e-7,
  DD 0.9999999991427051 2.3359102835920513e-9,
  DD 0.9999999999982322 6.172317347078991e-12],

 [DD 9.792388528783233e-2 9.742333472083313e-2,
  DD 0.2878799327427159 9.162590166981036e-2,
  DD 0.46125354393958573 8.109223440156113e-2,
  DD 0.610273657500639 6.76021865931294e-2,
  DD 0.7310180347925616 5.313580352853876e-2,
  DD 0.8233170055064024 3.940032094779648e-2,
  DD 0.8898914027842602 2.755207726711614e-2,
  DD 0.9351608575219846 1.8140042457028386e-2,
  DD 0.9641121642235473 1.1207775756920519e-2,
  DD 0.9814548266773352 6.464509638958307e-3,
  DD 0.9911269924416988 3.4556052338900363e-3,
  DD 0.9961086654375085 1.6958443758570002e-3,
  DD 0.9984542087676977 7.55221474947372e-4,
  DD 0.9994514344352746 3.0101863399552894e-4,
  DD 0.9998288220728749 1.0567962488391497e-4,
  DD 0.9999538710056279 3.208711400424396e-5,
  DD 0.9999894820148185 8.253271328506235e-6,
  DD 0.9999980171405954 1.7568852704962584e-6,
  DD 0.9999996988941526 3.014823877038469e-7,
  DD 0.9999999642390809 4.048597877245607e-8,
  DD 0.9999999967871991 4.114699070448963e-9,
  DD 0.9999999997897329 3.047503810890039e-10,
  DD 0.9999999999903939 1.5760217449081342e-11,
  DD 0.9999999999997081 5.422457134362253e-13],

 [DD 4.9055967305077885e-2 4.899316972835068e-2,
  DD 0.14641798429058794 4.8246284880529976e-2,
  DD 0.24156631953888366 4.678831945440738e-2,
  DD 0.33314226457763807 4.4687761089759366e-2,
  DD 0.41995211127844717 4.203996514894536e-2,
  DD 0.5010133893793091 3.8959412732870555e-2,
  DD 0.5755844906351517 3.557100760550954e-2,
  DD 0.6431767589852047 3.200140415974411e-2,
  DD 0.703550005147142 2.837123059859048e-2,
  DD 0.75669390863373 2.4788834400641148e-2,
  DD 0.8027987413432413 2.1345891135758244e-2,
  DD 0.8422192463507568 1.8114940721493365e-2,
  DD 0.8754353976304087 1.5148690350461106e-2,
  DD 0.9030132815135739 1.248077317267866e-2,
  DD 0.9255686340686127 1.0127579362860278e-2,
  DD 0.9437347860527572 8.090769984814172e-3,
  DD 0.9581360227102137 6.360124964331305e-3,
  DD 0.9693667328969173 4.916443858886442e-3,
  DD 0.977976235186665 3.7342941027717477e-3,
  DD 0.9844588311674308 2.7844731012794206e-3,
  DD 0.9892484310901339 2.0361104197667563e-3,
  DD 0.9927169971968273 1.4583815017139568e-3,
  DD 0.9951760261553274 1.0218353977065322e-3,
  DD 0.9968803181281919 6.993584707390149e-4,
  DD 0.9980333363154338 4.6680734675156655e-4,
  DD 0.9987935342988059 3.033507418559903e-4,
  DD 0.9992811119217919 1.915636760025947e-4,
  DD 0.9995847503515176 1.1732034304474483e-4,
  DD 0.9997679715995609 6.953383457745758e-5,
  DD 0.9998748650487803 3.979149827213244e-5,
  DD 0.9999350199250824 2.193310986513257e-5,
  DD 0.9999675930679435 1.16145917567743e-5,
  DD 0.9999845199022708 5.89263843021885e-6,
  DD 0.9999929378766629 2.8559630465846914e-6,
  DD 0.9999969324491904 1.318224495054925e-6,
  DD 0.9999987354718659 5.775566749962256e-7,
  DD 0.9999995070057195 2.393617453912599e-7,
  DD 0.9999998188937128 9.34894246191837e-8,
  DD 0.9999999375540783 3.4277609768441454e-8,
  DD 0.9999999798745032 1.1748566206987696e-8,
  DD 0.9999999939641342 3.7476383696571155e-9,
  DD 0.999999998323362 1.107336786606936e-9,
  DD 0.9999999995707878 3.015590280034051e-10,
  DD 0.9999999998992777 7.528679142648731e-11,
  DD 0.9999999999784553 1.713386181159218e-11,
  DD 0.9999999999958246 3.5331422960920875e-12,
  DD 0.9999999999992715 6.559167313909834e-13,
  DD 0.9999999999998863 1.088810552195658e-13],

 [DD 2.453976357464916e-2 2.4531906707493643e-2,
  DD 7.352512298567129e-2 2.443783443395675e-2,
  DD 0.12222912220155764 2.4250830778834564e-2,
  DD 0.17046797238201053 2.397315215866099e-2,
  DD 0.218063473469712 2.3608120673033903e-2,
  DD 0.26484507658344797 2.316005152946153e-2,
  DD 0.310651780552846 2.2634160233770666e-2,
  DD 0.35533382516507456 2.2036452678847795e-2,
  DD 0.3987541504672378 2.1373601745014008e-2,
  DD 0.44078959903390086 2.065281433505895e-2,
  DD 0.48133184611690505 1.9881692899029104e-2,
  DD 0.5202880506912302 1.9068095462177474e-2,
  DD 0.5575812282607783 1.821999796769429e-2,
  DD 0.5931503535919531 1.7345362405708442e-2,
  DD 0.6269502080510428 1.6452013749301043e-2,
  DD 0.6589509917433501 1.5547528188220824e-2,
  DD 0.6891377250616677 1.4639134574151062e-2,
  DD 0.7175094674873241 1.373363039926222e-2,
  DD 0.7440783835473473 1.2837313051046323e-2,
  DD 0.7688686867682466 1.1955926545452439e-2,
  DD 0.7919154923761421 1.1094623456335453e-2,
  DD 0.8132636085029739 1.025794134580668e-2,
  DD 0.8329662939194109 9.449792665287556e-3,
  DD 0.8510840079878488 8.673466843806774e-3,
  DD 0.867683175775646 7.931643106748563e-3,
  DD 0.882834988244669 7.226412469615121e-3,
  DD 0.896614254280076 6.559307319453367e-3,
  DD 0.9090983181630204 5.931337021666432e-3,
  DD 0.9203660530319528 5.343028061297138e-3,
  DD 0.9304969379971534 4.794467334654952e-3,
  DD 0.9395702239332747 4.285347338891689e-3,
  DD 0.9476641906151531 3.8150121542162487e-3,
  DD 0.9548554958050227 3.382503267457753e-3,
  DD 0.9612186151511164 2.9866044395848047e-3,
  DD 0.9668253703123558 2.6258849679417057e-3,
  DD 0.9717445415654873 2.2987408321540146e-3,
  DD 0.9760415602565767 2.0034333379875154e-3,
  DD 0.9797782758006157 1.7381249841991332e-3,
  DD 0.9830127914811011 1.5009123728935854e-3,
  DD 0.9857993630252835 1.2898560642297147e-3,
  DD 0.9881883538007427 1.103007342294797e-3,
  DD 0.9902262404675277 9.384319118536922e-4,
  DD 0.9919556630026776 7.942305870714137e-4,
  DD 0.993415513169264 6.685570649644637e-4,
  DD 0.9946410557125112 5.596329000655693e-4,
  DD 0.9956640768169531 4.6575981433297074e-4,
  DD 0.9965130546402537 3.8532948929302006e-4,
  DD 0.9972133470434688 3.1683099714843944e-4,
  DD 0.9977873919589065 2.5885603522261835e-4,
  DD 0.9982549161719962 2.1010213445758955e-4,
  DD 0.9986331486406774 1.6937401825399854e-4,
  DD 0.9989370348335121 1.355832929615497e-4,
  DD 0.999179448934886 1.077466557666563e-4,
  DD 0.9993714011409377 8.498280933787498e-5,
  DD 0.9995222376512172 6.650827498465403e-5,
  DD 0.9996398313456004 5.1632296781794225e-5,
  DD 0.9997307615198084 3.9751027617643327e-5,
  DD 0.9998004814311384 3.0341183999755742e-5,
  DD 0.9998534727731114 2.295334937410905e-5,
  DD 0.9998933865475925 1.7205095522686537e-5,
  DD 0.9999231701292893 1.2774078333198358e-5,
  DD 0.9999451806144587 9.391248123616785e-6,
  DD 0.9999612848078566 6.834296189986201e-6,
  DD 0.9999729464252323 4.921438935315812e-6,
  DD 0.9999813012701207 3.5056195632825857e-6,
  DD 0.9999872212820007 2.469185687609561e-6,
  DD 0.9999913684483449 1.7190801322916715e-6,
  DD 0.9999942396276167 1.182562446659398e-6,
  DD 0.9999962033471662 8.034608976196688e-7,
  DD 0.9999975296238052 5.389394493647375e-7,
  DD 0.9999984138109648 3.567518454536898e-7,
  DD 0.9999989954106899 2.3294553174797826e-7,
  DD 0.9999993727073354 1.499717832559136e-7,
  DD 0.9999996139885502 9.515484425148287e-8,
  DD 0.9999997660233324 5.947184885100765e-8,
  DD 0.9999998603712146 3.659635501332515e-8,
  DD 0.9999999180047947 2.2161042430459245e-8,
  DD 0.9999999526426645 1.3199024435134353e-8,
  DD 0.999999973113236 7.727857609805343e-9,
  DD 0.9999999850030763 4.44530057174372e-9,
  DD 0.999999991786456 2.5108429029806602e-9,
  DD 0.9999999955856336 1.3917405490662874e-9,
  DD 0.9999999976732368 7.565773468448808e-10,
  DD 0.9999999987979835 4.0311825358649834e-10,
  DD 0.9999999993917769 2.1038508628596934e-10,
  DD 0.9999999996987544 1.0747595461859219e-10,
  DD 0.9999999998540561 5.3706026163515766e-11,
  DD 0.9999999999308884 2.6232652628377978e-11,
  DD 0.9999999999680332 1.251559132495776e-11,
  DD 0.9999999999855688 5.828047162976999e-12,
  DD 0.9999999999936463 2.64679027959557e-12,
  DD 0.9999999999972741 1.1713655870909097e-12,
  DD 0.9999999999988612 5.047572552070682e-13,
  DD 0.9999999999995373 2.116017642552543e-13,
  DD 0.9999999999998171 8.622245229402326e-14,
  DD 0.9999999999999298 3.411862828005251e-14],

 [DD 1.2271355118082201e-2 1.2270372785455275e-2,
  DD 3.6802280950025086e-2 1.2258591369934915e-2,
  DD 6.1297889413659976e-2 1.2235064366542666e-2,
  DD 8.573475487765106e-2 1.219986323040477e-2,
  DD 0.11008962993262801 1.2153094645559847e-2,
  DD 0.13433951528767224 1.2094899931527792e-2,
  DD 0.1584617282892995 1.2025454260249077e-2,
  DD 0.18243396969028916 1.1944965690270162e-2,
  DD 0.20623438831102878 1.185367402660199e-2,
  DD 0.22984164325436077 1.1751849516122478e-2,
  DD 0.2532349633560002 1.1639791389713258e-2,
  DD 0.2763942035761786 1.1517826263500622e-2,
  DD 0.29929989806396046 1.1386306412598036e-2,
  DD 0.3219333096533692 1.1245607931612554e-2,
  DD 0.3442764755797049 1.1096128796872587e-2,
  DD 0.3663122492349041 1.0938286845855036e-2,
  DD 0.38802433781211776 1.0772517689633887e-2,
  DD 0.4093973357215295 1.0599272574340667e-2,
  DD 0.43041675369143706 1.0419016207623095e-2,
  DD 0.451069043500452 1.0232224565917498e-2,
  DD 0.4713416183179985 1.0039382698021307e-2,
  DD 0.4912228686608115 9.840982539973989e-3,
  DD 0.5107021740025581 9.637520755640209e-3,
  DD 0.5297699101017745 9.429496616650846e-3,
  DD 0.5484174521397923 9.21740993451042e-3,
  DD 0.5666371737850189 9.001759056738652e-3,
  DD 0.5844224423226639 8.783038937895338e-3,
  DD 0.6017676100096334 8.561739295257595e-3,
  DD 0.6186680018327281 8.338342857792998e-3,
  DD 0.6351198998644219 8.113323715917128e-3,
  DD 0.6511205244243042 7.88714577835492e-3,
  DD 0.6666680122657377 7.66026134125668e-3,
  DD 0.6817613920164273 7.4331097735652555e-3,
  DD 0.6964005571084592 7.206116321503556e-3,
  DD 0.7105862364380058 6.979691033962469e-3,
  DD 0.7243199629974075 6.754227809528664e-3,
  DD 0.7376040407228253 6.530103564908337e-3,
  DD 0.7504415097992404 6.307677523584086e-3,
  DD 0.7628361106613923 6.087290622693735e-3,
  DD 0.7747922469244354 5.869265035346538e-3,
  DD 0.7863149474718196 5.653903804897112e-3,
  DD 0.7974098279203122 5.441490587082398e-3,
  DD 0.8080830516733385 5.232289495392899e-3,
  DD 0.8183412907640978 5.026545044595726e-3,
  DD 0.828191686679357 4.824482186952413e-3,
  DD 0.8376418113436 4.626306435376617e-3,
  DD 0.8466996284314637 4.432204067552646e-3,
  DD 0.8553734551642715 4.2423424048815845e-3,
  DD 0.8636719247341053 4.056870160033175e-3,
  DD 0.8716039494863778 3.875917846854033e-3,
  DD 0.8791786849793893 3.699598246411047e-3,
  DD 0.8864054950269787 3.528006923027695e-3,
  DD 0.893293917818211 3.3612227842952265e-3,
  DD 0.8998536331961702 3.199308679204638e-3,
  DD 0.9060944311664042 3.042312028743844e-3,
  DD 0.9120261816944868 2.8902654835321396e-3,
  DD 0.9176588058415494 2.7431876033158224e-3,
  DD 0.9230022482765544 2.6010835534199046e-3,
  DD 0.9280664511945551 2.463945813536548e-3,
  DD 0.93286132966124 2.331754894526914e-3,
  DD 0.9373967483957192 2.2044800592155946e-3,
  DD 0.9416824999957694 2.0820800434619936e-3,
  DD 0.9457282846026323 1.9645037740977376e-3,
  DD 0.9495436909959364 1.8516910806204608e-3,
  DD 0.9531381791033938 1.743573397829567e-3,
  DD 0.9565210639045809 1.6400744568766214e-3,
  DD 0.9597015007033366 1.5411109624799781e-3,
  DD 0.9626884717390782 1.4465932543185588e-3,
  DD 0.9654907741036205 1.3564259508721196e-3,
  DD 0.9681170089268564 1.2705085742139401e-3,
  DD 0.9705755717919005 1.1887361544859352e-3,
  DD 0.9728746443379639 1.1109998129953268e-3,
  DD 0.9750221870073064 1.0371873230659806e-3,
  DD 0.977025932891058 9.671836479563513e-4,
  DD 0.978893382627494 9.00871455319823e-4,
  DD 0.9806318003054487 8.381316078324722e-4,
  DD 0.982248210324941 7.788436297483483e-4,
  DD 0.9837493951667312 7.228861492638943e-4,
  DD 0.985141894022398 6.701373166817827e-4,
  DD 0.9864320022366084 6.204751984610012e-4,
  DD 0.9876257715135107 5.737781473253029e-4,
  DD 0.9887290108396024 5.299251486770154e-4,
  DD 0.9897472880759871 4.887961436285556e-4,
  DD 0.9906859321736151 4.5027232902074006e-4,
  DD 0.9915500359658918 4.142364348459936e-4,
  DD 0.9923444594939181 3.805729795367299e-4,
  DD 0.9930738338205845 3.491685036153557e-4,
  DD 0.9937425652907617 3.199117822333383e-4,
  DD 0.9943548401959209 2.9269401715335136e-4,
  DD 0.9949146298026389 2.6740900875137265e-4,
  DD 0.9954256957056228 2.4395330863540422e-4,
  DD 0.9958915954671002 2.2222635349479874e-4,
  DD 0.9963156885056609 2.0213058080951283e-4,
  DD 0.9967011421989126 1.8357152706241037e-4,
  DD 0.9970509381656091 1.6645790911035992e-4,
  DD 0.9973678786942355 1.5070168938160626e-4,
  DD 0.9976545932863778 1.362181255779489e-4,
  DD 0.997913545284577 1.2292580557077967e-4,
  DD 0.9981470385557484 1.1074666819008172e-4,
  DD 0.9983572242026638 9.960601061508721e-5,
  DD 0.9985461072774127 8.94324830843731e-5,
  DD 0.9987155534722089 8.015807165164663e-5,
  DD 0.9988672957643638 7.171806972117892e-5,
  DD 0.9990029409937289 6.405103910360313e-5,
  DD 0.9991239763523898 5.709876133838475e-5,
  DD 0.9992317757678989 5.080618003345765e-5,
  DD 0.99932760616283 4.5121334975051167e-5,
  DD 0.9994126335749526 3.999528876135767e-5,
  DD 0.9994879291238233 3.538204671215851e-5,
  DD 0.9995544748110967 3.123847080260571e-5,
  DD 0.9996131691433469 2.752418836283583e-5,
  DD 0.9996648325676647 2.420149627578766e-5,
  DD 0.9997102127117511 2.1235261393361145e-5,
  DD 0.9997499894216488 1.8592817875784673e-5,
  DD 0.9997847795916511 1.6243862140692703e-5,
  DD 0.999815141782273 1.4160346086944252e-5,
  DD 0.999841580623482 1.2316369233676219e-5,
  DD 0.9998645510016351 1.0688070387575812e-5,
  DD 0.9998844620297662 9.253519421017792e-6,
  DD 0.9999016808020029 7.992609710738602e-6,
  DD 0.9999165359339512 6.886951751351328e-6,
  DD 0.9999293208918842 5.919768420526244e-6,
  DD 0.9999402971144794 5.0757923333928935e-6,
  DD 0.9999496969316893 4.34116568301395e-6,
  DD 0.9999577262860779 3.703342922016931e-6,
  DD 0.9999645672626261 3.1509965980432886e-6,
  DD 0.9999703804335893 2.6739266129920068e-6,
  DD 0.9999753070254921 2.2629731335060294e-6,
  DD 0.9999794709157516 1.909933338178841e-6,
  DD 0.9999829804667566 1.6074821459374078e-6,
  DD 0.9999859302054748 1.3490970303588222e-6,
  DD 0.9999884023568332 1.1289869866480146e-6,
  DD 0.9999904682392139 9.420256819575779e-7,
  DD 0.9999921895304337 7.836887859462829e-7,
  DD 0.9999936194125388 6.49995447187785e-7,
  DD 0.9999948036036489 5.374538524491904e-7,
  DD 0.9999957812849285 4.430107801088506e-7,
  DD 0.9999965859305708 3.640050361757392e-7,
  DD 0.9999972460484262 2.9812464156442e-7,
  DD 0.9999977858386352 2.4336762248006523e-7,
  DD 0.9999982257773113 1.980062419441415e-7,
  DD 0.9999985831319845 1.6055449956979878e-7,
  DD 0.9999988724151619 1.2973871856647137e-7,
  DD 0.9999991057819958 1.0447103347290916e-7,
  DD 0.9999992933776685 8.382558911603391e-8,
  DD 0.9999994436397289 6.701726057584303e-8,
  DD 0.9999995635602319 5.338270529235821e-8,
  DD 0.9999996589121594 4.236356165487526e-8,
  DD 0.999999734444233 3.349161323437361e-8,
  DD 0.9999997940478761 2.6375744021918055e-8,
  DD 0.9999998408997359 2.0690517385971415e-8,
  DD 0.9999998775828551 1.616621973231615e-8,
  DD 0.9999999061892685 1.2580218823834102e-8,
  DD 0.9999999284065142 9.749496188419885e-9,
  DD 0.9999999455902729 7.52422282169213e-9,
  DD 0.9999999588251015 5.782257303977235e-9,
  DD 0.9999999689749902 4.424455343910217e-9,
  DD 0.9999999767252671 3.3706894989972953e-9,
  DD 0.9999999826171735 2.556487291446684e-9,
  DD 0.9999999870762648 1.930205039941383e-9,
  DD 0.9999999904356328 1.4506633882832136e-9,
  DD 0.9999999929548045 1.0851786715653089e-9,
  DD 0.9999999948350508 8.079318781832505e-10,
  DD 0.999999996231727 5.986240154282624e-10,
  DD 0.9999999972641738 4.413731552474267e-10,
  DD 0.9999999980236194 3.238143246758233e-10,
  DD 0.999999998579458 2.3636872238202706e-10,
  DD 0.9999999989842099 1.7165350716476053e-10,
  DD 0.999999999277422 1.2400764133568933e-10,
  DD 0.9999999994887183 8.911301214726938e-11,
  DD 0.9999999996401729 6.369333189732542e-11,
  DD 0.9999999997481464 4.5276168539817236e-11,
  DD 0.9999999998246986 3.200592120287906e-11,
  DD 0.9999999998786702 2.249766676911805e-11,
  DD 0.999999999916506 1.5723601733489977e-11,
  DD 0.9999999999428774 1.0925323681691751e-11,
  DD 0.9999999999611503 7.546472801414007e-12,
  DD 0.9999999999737366 5.181317458606414e-12,
  DD 0.9999999999823534 3.535748133137017e-12,
  DD 0.9999999999882166 2.39786734990026e-12,
  DD 0.9999999999921814 1.6159534014866576e-12,
  DD 0.9999999999948451 1.0820537129557926e-12,
  DD 0.9999999999966235 7.198481580196788e-13,
  DD 0.999999999997803 4.75729586440474e-13,
  DD 0.9999999999985799 3.1229210562445524e-13,
  DD 0.9999999999990884 2.0360906642816634e-13,
  DD 0.9999999999994189 1.3183218237433614e-13,
  DD 0.9999999999996322 8.475907683075875e-14,
  DD 0.9999999999997687 5.410568761928233e-14,
  DD 0.9999999999998558 3.428800929670258e-14,
  DD 0.9999999999999106 2.1569209118279908e-14,
  DD 0.999999999999945 1.3466909403158373e-14]]

